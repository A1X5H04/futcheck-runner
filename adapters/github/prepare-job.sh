#!/usr/bin/env bash
set -Eeuo pipefail

# GitHub platform contract: materialize a canonical Runner job and metadata.
WORK_DIR="${FUTCHECK_WORK_DIR:-${RUNNER_TEMP:-/tmp}/futcheck-work}"
JOB_FILE="${RUNNER_JOB_FILE:-$WORK_DIR/job.json}"
INPUT_DIR="${RUNNER_INPUT_DIR:-$WORK_DIR/input}"
OUTPUT_DIR="${RUNNER_OUTPUT_DIR:-$WORK_DIR/output}"
METADATA_FILE="${RUNNER_METADATA_FILE:-$WORK_DIR/runner_metadata.json}"
JOB_JSON="${FUTCHECK_JOB_JSON:-}"
JOB_ID="${FUTCHECK_JOB_ID:-}"
JOB_API_URL="${FUTCHECK_JOB_API_URL:-}"
JOB_TOKEN="${FUTCHECK_JOB_TOKEN:-}"
ALLOWED_HOSTS="${FUTCHECK_ALLOWED_JOB_HOSTS:-}"
RUNNER_METADATA_JSON="${FUTCHECK_RUNNER_METADATA:-}"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
[[ -z "$JOB_JSON" || -z "$JOB_ID" ]] || { echo "Provide job_json or job_id, not both." >&2; exit 2; }
[[ -n "$JOB_JSON" || -n "$JOB_ID" ]] || { echo "job_json or job_id is required." >&2; exit 2; }

if [[ -n "$JOB_JSON" ]]; then
  printf '%s' "$JOB_JSON" > "$JOB_FILE"
else
  [[ "$JOB_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || { echo "Invalid job_id." >&2; exit 2; }
  [[ "$JOB_API_URL" =~ ^https:// ]] || { echo "FUTCHECK_JOB_API_URL must use HTTPS." >&2; exit 2; }
  [[ -n "$JOB_TOKEN" ]] || { echo "FUTCHECK_JOB_TOKEN is required." >&2; exit 2; }
  [[ -n "$ALLOWED_HOSTS" && "$ALLOWED_HOSTS" != "*" ]] || { echo "FUTCHECK_ALLOWED_JOB_HOSTS is required." >&2; exit 2; }

  authority="${JOB_API_URL#https://}"; authority="${authority%%/*}"; host="${authority%%:*}"
  host_allowed=false
  IFS=',' read -r -a host_list <<< "$ALLOWED_HOSTS"
  for allowed in "${host_list[@]}"; do
    allowed="$(printf '%s' "$allowed" | tr '[:upper:]' '[:lower:]' | xargs)"
    [[ "${host,,}" != "$allowed" ]] || { host_allowed=true; break; }
  done
  [[ "$host_allowed" == true ]] || { echo "Job API host is outside the configured allowlist." >&2; exit 2; }

  if [[ "$JOB_API_URL" =~ /jobs/?$ ]]; then
    fetch_url="${JOB_API_URL%/}/$JOB_ID"
  else
    fetch_url="${JOB_API_URL%/}/api/workflow/runner/jobs/$JOB_ID"
  fi
  curl --fail --silent --show-error --connect-timeout 15 --max-time 60 \
    --header "Authorization: Bearer $JOB_TOKEN" --output "$JOB_FILE" "$fetch_url"
fi

jq -e '
  type == "object"
  and .schemaVersion == 1
  and ((keys - ["schemaVersion","jobId","action","actionVersion","payload","metadata"]) | length == 0)
  and (.jobId | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"))
  and (.action | type == "string" and test("^(?:[a-z][a-z0-9-]*\\.[a-z][a-z0-9-]*|[a-z][a-z0-9_-]*)$"))
  and (.actionVersion | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$"))
  and (.payload | type == "object")
  and ((.metadata // {}) | type == "object")
' "$JOB_FILE" >/dev/null || { echo "Backend returned a non-canonical Runner job." >&2; exit 2; }

if [[ -n "$RUNNER_METADATA_JSON" ]]; then
  printf '%s' "$RUNNER_METADATA_JSON" | jq -c -e 'type == "object"' > "$METADATA_FILE"
else
  jq -c '.metadata // {} | if type == "object" then . else {} end' "$JOB_FILE" > "$METADATA_FILE"
fi

chmod 0444 "$JOB_FILE"
echo "Prepared canonical Runner job $(jq -r '.jobId' "$JOB_FILE")."
