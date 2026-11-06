#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/captures"
EXECUTION_ID="33333333-3333-4333-8333-333333333333"

cat > "$TEMP_DIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
payload=""
callback_url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --data-binary) payload="${2#@}"; shift 2 ;;
    https://*) callback_url="$1"; shift ;;
    *) shift ;;
  esac
done
count=0
[[ ! -s "$FUTCHECK_CALL_COUNT" ]] || read -r count < "$FUTCHECK_CALL_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$FUTCHECK_CALL_COUNT"
cp "$payload" "$FUTCHECK_CAPTURE_DIR/$count.json"
printf '%s\n' "$callback_url" > "$FUTCHECK_CAPTURE_DIR/$count.url"
if [[ "${FUTCHECK_FAKE_CURL_MODE:-success}" == "fail" || ( "${FUTCHECK_FAKE_CURL_MODE:-success}" == "fail_after_start" && "$count" -gt 1 ) || ( "${FUTCHECK_FAKE_CURL_MODE:-success}" == "primary_fails" && "$callback_url" == *primary.invalid* ) ]]; then
  printf '{"error":"unavailable"}' > "$output"
  printf '503'
else
  event_ids="$(jq -c '[.events[].eventId]' "$payload")"
  message_ids="$(jq -c '[.messages[].messageId]' "$payload")"
  printf '{"acceptedEventIds":%s,"acceptedMessageIds":%s,"abortJobs":[]}' "$event_ids" "$message_ids" > "$output"
  printf '200'
fi
CURL
chmod +x "$TEMP_DIR/bin/curl"

common_env=(
  PATH="$TEMP_DIR/bin:$PATH"
  RUNNER_REQUIRE_CALLBACK=true
  RUNNER_CONTROL_URL=https://example.invalid/callback
  RUNNER_ALLOWED_CALLBACK_HOSTS=example.invalid
  RUNNER_TOKEN=test-token
  RUNNER_STARTUP_DELIVERY_SECONDS=3
  RUNNER_FINAL_DELIVERY_SECONDS=3
  FUTCHECK_CALL_COUNT="$TEMP_DIR/call-count"
  FUTCHECK_CAPTURE_DIR="$TEMP_DIR/captures"
)

env "${common_env[@]}" RUNNER_WORK_DIR="$TEMP_DIR/success" \
  "$ROOT_DIR/runner/supervisor.sh" "$EXECUTION_ID" bash -c 'exit 0'

[[ "$(cat "$TEMP_DIR/call-count")" == "2" ]]
jq -e '.events | length == 1 and .events[0].code == "RUNNER_STARTED"' "$TEMP_DIR/captures/1.json" >/dev/null
jq -e '.events | length == 1 and .events[0].code == "JOB_COMPLETED"' "$TEMP_DIR/captures/2.json" >/dev/null
! find "$TEMP_DIR/success/outbox" -name '*.pending.jsonl' -o -name "$EXECUTION_ID.jsonl" | grep -q .

rm -f "$TEMP_DIR/call-count"
rm -rf "$TEMP_DIR/captures"
mkdir -p "$TEMP_DIR/captures"
if env "${common_env[@]}" FUTCHECK_FAKE_CURL_MODE=fail RUNNER_WORK_DIR="$TEMP_DIR/failure" \
  "$ROOT_DIR/runner/supervisor.sh" "$EXECUTION_ID" bash -c 'touch "$0"' "$TEMP_DIR/worker-started"; then
  echo "Expected unavailable startup acknowledgement to refuse the worker." >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 78 ]]
fi
[[ ! -e "$TEMP_DIR/worker-started" ]]
compgen -G "$TEMP_DIR/failure/outbox/$EXECUTION_ID.*.pending.jsonl" >/dev/null

DELIVERY_ID="44444444-4444-4444-8444-444444444444"
rm -f "$TEMP_DIR/call-count"
rm -rf "$TEMP_DIR/captures"
mkdir -p "$TEMP_DIR/captures"
if env "${common_env[@]}" FUTCHECK_FAKE_CURL_MODE=fail_after_start RUNNER_WORK_DIR="$TEMP_DIR/delivery-failure" \
  "$ROOT_DIR/runner/supervisor.sh" "$DELIVERY_ID" bash -c 'exit 0'; then
  echo "Expected an unacknowledged terminal result to fail the platform run." >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 74 ]]
fi
jq -e '.code == "TERMINAL_DELIVERY_PENDING"' "$TEMP_DIR/delivery-failure/outbox/$DELIVERY_ID.state.json" >/dev/null
compgen -G "$TEMP_DIR/delivery-failure/outbox/$DELIVERY_ID.*.pending.jsonl" >/dev/null

FALLBACK_ID="55555555-5555-4555-8555-555555555555"
rm -f "$TEMP_DIR/call-count"
rm -rf "$TEMP_DIR/captures"
mkdir -p "$TEMP_DIR/captures"
env "${common_env[@]}" FUTCHECK_FAKE_CURL_MODE=primary_fails \
  RUNNER_CONTROL_URL=https://primary.invalid/callback \
  WEBHOOK_CALLBACK_URL=https://example.invalid/callback \
  RUNNER_ALLOWED_CALLBACK_HOSTS=primary.invalid,example.invalid \
  RUNNER_WORK_DIR="$TEMP_DIR/fallback" \
  "$ROOT_DIR/runner/supervisor.sh" "$FALLBACK_ID" bash -c 'exit 0'
[[ "$(cat "$TEMP_DIR/captures/1.url")" == "https://primary.invalid/callback" ]]
[[ "$(cat "$TEMP_DIR/captures/2.url")" == "https://example.invalid/callback" ]]
jq -e '.events[0].code == "RUNNER_STARTED"' "$TEMP_DIR/captures/2.json" >/dev/null
[[ "$(cat "$TEMP_DIR/call-count")" == "4" ]]

echo "Startup gate and terminal reporting tests passed."
