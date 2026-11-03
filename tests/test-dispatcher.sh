#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/work/outbox"
JOB_ID="11111111-1111-4111-8111-111111111111"

cat > "$TEMP_DIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
payload=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --data-binary) payload="${2#@}"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$payload" "$FUTCHECK_CAPTURED_PAYLOAD"
printf '{"success":true,"abortJobs":["11111111-1111-4111-8111-111111111111"]}' > "$output"
printf '200'
CURL
chmod +x "$TEMP_DIR/bin/curl"

printf '%s\n' '{"jobId":"11111111-1111-4111-8111-111111111111","seq":1,"timestamp":1,"status":"RUNNING","phase":"test","logs":"","result":null,"error":null,"metadata":{}}' \
  > "$TEMP_DIR/work/outbox/$JOB_ID.jsonl"

FUTCHECK_CAPTURED_PAYLOAD="$TEMP_DIR/payload.json" \
PATH="$TEMP_DIR/bin:$PATH" RUNNER_WORK_DIR="$TEMP_DIR/work" \
BACKEND_STATUS_URL="https://example.invalid/callback" RUNNER_TOKEN="test-token" \
RUNNER_DISPATCH_INTERVAL_SECONDS=1 "$ROOT_DIR/runner/dispatcher.sh"

jq -e '.events | length == 1 and .[0].jobId == "11111111-1111-4111-8111-111111111111"' \
  "$TEMP_DIR/payload.json" >/dev/null
[[ -e "$TEMP_DIR/work/outbox/$JOB_ID.abort" ]]
[[ ! -e "$TEMP_DIR/work/outbox/$JOB_ID.lock.jsonl" ]]

echo "Dispatcher delivery tests passed."
