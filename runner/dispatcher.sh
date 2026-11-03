#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${RUNNER_WORK_DIR:-${FUTCHECK_WORK_DIR:-$ROOT_DIR/.work}}"
OUTBOX_DIR="$WORK_DIR/outbox"
CALLBACK_URL="${BACKEND_STATUS_URL:-${FUTCHECK_CALLBACK_URL:-}}"
RUNNER_TOKEN="${RUNNER_TOKEN:-${FUTCHECK_JOB_TOKEN:-}}"
INTERVAL="${RUNNER_DISPATCH_INTERVAL_SECONDS:-15}"

[[ -n "$CALLBACK_URL" ]] || exit 0
[[ -n "$RUNNER_TOKEN" ]] || exit 0
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || exit 2
mkdir -p "$OUTBOX_DIR"

lock_id="$(printf '%s' "$OUTBOX_DIR" | cksum | awk '{print $1}')"
exec 9>"/tmp/futcheck-dispatcher-$lock_id.lock"
flock -n 9 || exit 0

payload_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f "$payload_file" "$response_file"' EXIT

while true; do
  has_work=false
  for marker in "$OUTBOX_DIR"/*.active "$OUTBOX_DIR"/*.jsonl; do
    if [[ -e "$marker" ]]; then has_work=true; break; fi
  done
  [[ "$has_work" == true ]] || break

  for event_file in "$OUTBOX_DIR"/*.jsonl; do
    [[ -e "$event_file" ]] || continue
    [[ "$event_file" == *.lock.jsonl ]] && continue
    mv "$event_file" "${event_file%.jsonl}.lock.jsonl"
  done

  printf '{"activeJobs":[' > "$payload_file"
  comma=""
  for active_file in "$OUTBOX_DIR"/*.active; do
    [[ -e "$active_file" ]] || continue
    job_id="$(basename "$active_file" .active)"
    [[ "$job_id" =~ ^[0-9a-fA-F-]{36}$ ]] || continue
    printf '%s"%s"' "$comma" "$job_id" >> "$payload_file"
    comma=","
  done
  printf '],"events":[' >> "$payload_file"
  comma=""
  for locked_file in "$OUTBOX_DIR"/*.lock.jsonl; do
    [[ -e "$locked_file" ]] || continue
    while IFS= read -r event || [[ -n "$event" ]]; do
      [[ -n "$event" ]] || continue
      printf '%s%s' "$comma" "$event" >> "$payload_file"
      comma=","
    done < "$locked_file"
  done
  printf ']}' >> "$payload_file"

  set +e
  http_code="$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --output "$response_file" --write-out '%{http_code}' \
    --request POST "$CALLBACK_URL" \
    --header "Authorization: Bearer $RUNNER_TOKEN" \
    --header 'Content-Type: application/json' \
    --data-binary "@$payload_file")"
  curl_status=$?
  set -e

  if (( curl_status == 0 )) && [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    for locked_file in "$OUTBOX_DIR"/*.lock.jsonl; do
      [[ -e "$locked_file" ]] && rm -f "$locked_file"
    done
    if [[ -s "$response_file" ]]; then
      grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}' "$response_file" |
        while IFS= read -r abort_job; do touch "$OUTBOX_DIR/$abort_job.abort"; done || true
    fi
  fi

  sleep "$INTERVAL"
done
