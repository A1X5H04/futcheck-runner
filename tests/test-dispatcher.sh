#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/work/outbox"
EXECUTION_ID="11111111-1111-4111-8111-111111111111"

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
if [[ "${FUTCHECK_FAKE_CURL_MODE:-success}" == "fail" ]]; then
  printf '{"error":"temporary"}' > "$output"
  printf '503'
  exit 0
fi
accepted="$(jq '[.events[].seq] | max' "$payload")"
printf '{"acceptedThrough":%s,"abortJobs":[]}' "$accepted" > "$output"
printf '200'
CURL
chmod +x "$TEMP_DIR/bin/curl"

event() {
  local seq="$1"
  printf '{"executionId":"%s","jobId":"job","attempt":1,"seq":%s,"timestamp":1,"status":"STARTED","phase":"test","code":"TEST","message":"test","logs":"","result":null,"error":null,"metadata":{}}\n' "$EXECUTION_ID" "$seq"
}

event 1 > "$TEMP_DIR/work/outbox/$EXECUTION_ID.jsonl"
if FUTCHECK_FAKE_CURL_MODE=fail FUTCHECK_CAPTURED_PAYLOAD="$TEMP_DIR/failed-payload.json" \
  PATH="$TEMP_DIR/bin:$PATH" RUNNER_WORK_DIR="$TEMP_DIR/work" \
  BACKEND_STATUS_URL="https://example.invalid/callback" RUNNER_TOKEN="test-token" \
  RUNNER_ALLOWED_CALLBACK_HOSTS="example.invalid" \
  "$ROOT_DIR/runner/dispatcher.sh" --once --execution-id "$EXECUTION_ID"; then
  echo "Expected failed delivery to retain its pending batch." >&2
  exit 1
fi
compgen -G "$TEMP_DIR/work/outbox/$EXECUTION_ID.*.pending.jsonl" >/dev/null

event 2 > "$TEMP_DIR/work/outbox/$EXECUTION_ID.jsonl"
FUTCHECK_CAPTURED_PAYLOAD="$TEMP_DIR/success-payload.json" \
  PATH="$TEMP_DIR/bin:$PATH" RUNNER_WORK_DIR="$TEMP_DIR/work" \
  BACKEND_STATUS_URL="https://example.invalid/callback" RUNNER_TOKEN="test-token" \
  RUNNER_ALLOWED_CALLBACK_HOSTS="example.invalid" \
  "$ROOT_DIR/runner/dispatcher.sh" --once --execution-id "$EXECUTION_ID"

[[ ! -e "$TEMP_DIR/work/outbox/$EXECUTION_ID.jsonl" ]]
! compgen -G "$TEMP_DIR/work/outbox/$EXECUTION_ID.*.pending.jsonl" >/dev/null
jq -e '.events | length == 1 and .events[0].seq == 2' "$TEMP_DIR/success-payload.json" >/dev/null

echo "Dispatcher acknowledgement and immutable-batch tests passed."
