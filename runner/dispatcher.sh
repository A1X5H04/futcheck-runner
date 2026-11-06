#!/usr/bin/env bash
set -Eeuo pipefail

# One delivery pass. Events are first claimed into immutable pending batches.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${RUNNER_WORK_DIR:-${FUTCHECK_WORK_DIR:-$ROOT_DIR/.work}}"
OUTBOX_DIR="$WORK_DIR/outbox"
PRIMARY_CALLBACK_URL="${RUNNER_CONTROL_URL:-${BACKEND_STATUS_URL:-}}"
FALLBACK_CALLBACK_URL="${FUTCHECK_CALLBACK_URL:-}"
RUNNER_TOKEN="${RUNNER_TOKEN:-${FUTCHECK_JOB_TOKEN:-}}"
CALLBACK_ALLOWED_HOSTS="${RUNNER_ALLOWED_CALLBACK_HOSTS:-${FUTCHECK_ALLOWED_CALLBACK_HOSTS:-}}"
LOCK_WAIT="${RUNNER_DISPATCH_LOCK_WAIT_SECONDS:-35}"
ONCE=false
VALIDATE_CONFIG=false
FILTER_EXECUTION_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) ONCE=true; shift ;;
    --validate-config) VALIDATE_CONFIG=true; shift ;;
    --execution-id) FILTER_EXECUTION_ID="${2:?Missing execution id}"; shift 2 ;;
    *) echo "Usage: runner/dispatcher.sh [--once|--validate-config] [--execution-id <uuid>]" >&2; exit 2 ;;
  esac
done
UUID_PATTERN='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
[[ -z "$FILTER_EXECUTION_ID" || "$FILTER_EXECUTION_ID" =~ $UUID_PATTERN ]] || exit 2
[[ "$ONCE" != true || "$VALIDATE_CONFIG" != true ]] || exit 2
[[ "$LOCK_WAIT" =~ ^[1-9][0-9]*$ ]] || exit 2

url_is_allowed() {
  local url="$1" authority host allowed
  [[ "$url" =~ ^https:// ]] || return 1
  [[ -n "$CALLBACK_ALLOWED_HOSTS" && "$CALLBACK_ALLOWED_HOSTS" != "*" ]] || return 1
  authority="${url#https://}"
  authority="${authority%%/*}"
  host="${authority%%:*}"
  [[ -n "$host" ]] || return 1
  IFS=',' read -r -a allowed_hosts <<< "$CALLBACK_ALLOWED_HOSTS"
  for allowed in "${allowed_hosts[@]}"; do
    allowed="$(printf '%s' "$allowed" | tr '[:upper:]' '[:lower:]' | xargs)"
    [[ -z "$allowed" || "${host,,}" != "$allowed" ]] || return 0
  done
  return 1
}

CALLBACK_URLS=()
for candidate in "$PRIMARY_CALLBACK_URL" "$FALLBACK_CALLBACK_URL"; do
  [[ -n "$candidate" ]] || continue
  url_is_allowed "$candidate" || continue
  duplicate=false
  for existing in "${CALLBACK_URLS[@]}"; do
    [[ "$existing" != "$candidate" ]] || duplicate=true
  done
  [[ "$duplicate" == true ]] || CALLBACK_URLS+=("$candidate")
done
[[ -n "$RUNNER_TOKEN" && ${#CALLBACK_URLS[@]} -gt 0 ]] || exit 2
[[ "$VALIDATE_CONFIG" == false ]] || exit 0

mkdir -p "$OUTBOX_DIR" "$OUTBOX_DIR/quarantine"

lock_id="$(printf '%s' "$OUTBOX_DIR" | cksum | awk '{print $1}')"
exec 9>"/tmp/futcheck-dispatcher-$lock_id.lock"
if [[ "$ONCE" == true ]]; then
  flock -w "$LOCK_WAIT" 9 || exit 75
else
  flock -n 9 || exit 0
fi

timestamp="$(date +%s%N)"
for source_file in "$OUTBOX_DIR"/*.jsonl; do
  [[ -e "$source_file" ]] || continue
  base="$(basename "$source_file")"
  execution_id="${base%.jsonl}"
  [[ "$execution_id" =~ $UUID_PATTERN ]] || continue
  [[ -z "$FILTER_EXECUTION_ID" || "$execution_id" == "$FILTER_EXECUTION_ID" ]] || continue
  first_seq="$(head -n 1 "$source_file" | jq -r '.seq // 0' 2>/dev/null || printf '0')"
  last_seq="$(tail -n 1 "$source_file" | jq -r '.seq // 0' 2>/dev/null || printf '0')"
  [[ "$first_seq" =~ ^[0-9]+$ ]] || first_seq=0
  [[ "$last_seq" =~ ^[0-9]+$ ]] || last_seq=0
  printf -v first_padded '%020d' "$first_seq"
  printf -v last_padded '%020d' "$last_seq"
  pending_file="$OUTBOX_DIR/${execution_id}.${first_padded}-${last_padded}.${timestamp}.$$.pending.jsonl"
  mv "$source_file" "$pending_file"
  chmod 0444 "$pending_file"
done

delivery_failed=false
for pending_file in "$OUTBOX_DIR"/*.pending.jsonl; do
  [[ -e "$pending_file" ]] || continue
  pending_base="$(basename "$pending_file")"
  [[ -z "$FILTER_EXECUTION_ID" || "$pending_base" == "$FILTER_EXECUTION_ID".* ]] || continue
  pending_execution_id="${pending_base%%.*}"
  [[ "$pending_execution_id" =~ $UUID_PATTERN ]] || continue
  payload_file="$(mktemp)"
  response_file="$(mktemp)"
  valid_file="$(mktemp)"

  while IFS= read -r event || [[ -n "$event" ]]; do
    [[ -n "$event" ]] || continue
    if jq -e --arg executionId "$pending_execution_id" '
      type == "object"
      and .executionId == $executionId
      and (.seq | type == "number" and floor == . and . >= 1)
      and (.status | IN("STARTED", "COMPLETED", "FAILED", "CANCELLED"))
      and (.code | type == "string" and test("^[A-Z][A-Z0-9_]*$"))
      and (.message | type == "string" and length > 0)
    ' >/dev/null 2>&1 <<< "$event"; then
      printf '%s\n' "$event" >> "$valid_file"
    else
      printf '%s\n' "$event" >> "$OUTBOX_DIR/quarantine/$(basename "$pending_file").invalid.jsonl"
    fi
  done < "$pending_file"

  if [[ ! -s "$valid_file" ]]; then
    rm -f "$pending_file" "$payload_file" "$response_file" "$valid_file"
    continue
  fi

  max_seq="$(jq -s 'map(.seq) | max' "$valid_file")"
  jq -s '{activeJobs:[],events:.}' "$valid_file" > "$payload_file"

  accepted_through=""
  for callback_url in "${CALLBACK_URLS[@]}"; do
    : > "$response_file"
    set +e
    http_code="$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
      --output "$response_file" --write-out '%{http_code}' --request POST "$callback_url" \
      --header "Authorization: Bearer $RUNNER_TOKEN" --header 'Content-Type: application/json' \
      --data-binary "@$payload_file")"
    curl_status=$?
    set -e
    if (( curl_status == 0 )) && [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      accepted_through="$(jq -r '.acceptedThrough // empty' "$response_file" 2>/dev/null || true)"
      [[ "$accepted_through" =~ ^[0-9]+$ ]] && (( accepted_through >= max_seq )) && break
    fi
  done

  if [[ "$accepted_through" =~ ^[0-9]+$ ]] && (( accepted_through >= max_seq )); then
    rm -f "$pending_file"
    jq -r '.abortJobs[]? // empty' "$response_file" 2>/dev/null |
      while IFS= read -r abort_job; do
        [[ "$abort_job" =~ $UUID_PATTERN ]] && touch "$OUTBOX_DIR/$abort_job.abort"
      done
  else
    delivery_failed=true
    rm -f "$payload_file" "$response_file" "$valid_file"
    break
  fi

  rm -f "$payload_file" "$response_file" "$valid_file"
done

[[ "$delivery_failed" == false ]]
