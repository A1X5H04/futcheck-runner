#!/usr/bin/env bash
set -Eeuo pipefail

WORK_DIR="${FUTCHECK_WORK_DIR:-${RUNNER_TEMP:-/tmp}/futcheck-work}"
JOB_FILE="$WORK_DIR/job.json"
INPUT_DIR="$WORK_DIR/input"
OUTPUT_DIR="$WORK_DIR/output"
JOB_JSON="${FUTCHECK_JOB_JSON:-}"
JOB_ID="${FUTCHECK_JOB_ID:-}"
JOB_API_URL="${FUTCHECK_JOB_API_URL:-}"
JOB_TOKEN="${FUTCHECK_JOB_TOKEN:-}"
ALLOWED_HOSTS="${FUTCHECK_ALLOWED_JOB_HOSTS:-}"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

if [[ -n "$JOB_JSON" && -n "$JOB_ID" ]]; then
  echo "Provide either job_json or job_id, not both." >&2
  exit 2
fi
if [[ -z "$JOB_JSON" && -z "$JOB_ID" ]]; then
  echo "A job_json or job_id workflow input is required." >&2
  exit 2
fi

if [[ -n "$JOB_JSON" ]]; then
  printf '%s' "$JOB_JSON" > "$JOB_FILE"
else
  [[ "$JOB_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || { echo "Invalid job_id." >&2; exit 2; }
  [[ "$JOB_API_URL" == https://* ]] || { echo "FUTCHECK_JOB_API_URL must use HTTPS." >&2; exit 2; }
  [[ -n "$JOB_TOKEN" ]] || { echo "FUTCHECK_JOB_TOKEN is required when retrieving a job by ID." >&2; exit 2; }
  URL_WITHOUT_SCHEME="${JOB_API_URL#https://}"
  URL_AUTHORITY="${URL_WITHOUT_SCHEME%%/*}"
  URL_HOST="${URL_AUTHORITY%%:*}"
  [[ -n "$URL_HOST" && "$URL_HOST" != *"@"* && "$JOB_API_URL" != *"?"* && "$JOB_API_URL" != *"#"* ]] || {
    echo "Invalid job API URL. Use an HTTPS base URL without credentials, query strings, or fragments." >&2
    exit 2
  }
  [[ -n "$ALLOWED_HOSTS" ]] || { echo "FUTCHECK_ALLOWED_JOB_HOSTS must be configured when retrieving jobs by ID." >&2; exit 2; }

  HOST_ALLOWED=false
  IFS=',' read -r -a HOST_LIST <<< "$ALLOWED_HOSTS"
  for allowed_host in "${HOST_LIST[@]}"; do
    allowed_host="$(printf '%s' "$allowed_host" | tr '[:upper:]' '[:lower:]' | xargs)"
    if [[ "${URL_HOST,,}" == "$allowed_host" ]]; then
      HOST_ALLOWED=true
      break
    fi
  done
  [[ "$HOST_ALLOWED" == true ]] || { echo "Job API host is not in the configured allowlist." >&2; exit 2; }

  curl --fail --silent --show-error \
    --proto '=https' \
    --max-redirs 0 \
    --connect-timeout 10 \
    --max-time 60 \
    --header "Authorization: Bearer ${JOB_TOKEN}" \
    --output "$JOB_FILE" \
    "${JOB_API_URL%/}/${JOB_ID}"
fi

jq -e 'type == "object" and .schemaVersion == 1 and (.jobId | type == "string" and length > 0) and (.action | type == "string" and length > 0) and (.actionVersion | type == "string" and length > 0) and (.payload | type == "object")' "$JOB_FILE" >/dev/null \
  || { echo "The retrieved job does not match the Runner job envelope." >&2; exit 2; }

chmod 0444 "$JOB_FILE"
echo "Prepared job $(jq -r '.jobId' "$JOB_FILE") at $JOB_FILE"
