#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${RUNNER_WORK_DIR:-${FUTCHECK_WORK_DIR:-$ROOT_DIR/.work}}"
OUTBOX_DIR="$WORK_DIR/outbox"
EXECUTION_ID="${1:-}"
REQUIRE_CALLBACK="${RUNNER_REQUIRE_CALLBACK:-false}"
STALE_LOCK_SECONDS="${RUNNER_STALE_LOCK_SECONDS:-3600}"
STARTUP_DELIVERY_SECONDS="${RUNNER_STARTUP_DELIVERY_SECONDS:-45}"
FINAL_DELIVERY_SECONDS="${RUNNER_FINAL_DELIVERY_SECONDS:-45}"
EXECUTION_TIMEOUT_SECONDS="${RUNNER_EXECUTION_TIMEOUT_SECONDS:-900}"
ATTEMPT="${RUNNER_ATTEMPT:-1}"
PLATFORM="${RUNNER_PLATFORM:-unknown}"
PLATFORM_RUN_ID="${RUNNER_PLATFORM_RUN_ID:-}"
JOB_FILE="${RUNNER_JOB_FILE:-}"

usage() {
  echo "Usage: runner/supervisor.sh <execution-uuid> [--preflight <command> [args...] --] <command> [args...]" >&2
}

[[ "$EXECUTION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] || { usage; exit 2; }
shift
PREFLIGHT_COMMAND=()
if [[ "${1:-}" == "--preflight" ]]; then
  shift
  while [[ $# -gt 0 && "$1" != "--" ]]; do PREFLIGHT_COMMAND+=("$1"); shift; done
  [[ ${#PREFLIGHT_COMMAND[@]} -gt 0 && "${1:-}" == "--" ]] || { usage; exit 2; }
  shift
fi
[[ $# -gt 0 ]] || { usage; exit 2; }
WORKER_COMMAND=("$@")
[[ "$REQUIRE_CALLBACK" == "true" || "$REQUIRE_CALLBACK" == "false" ]] || exit 2
for number in "$STALE_LOCK_SECONDS" "$STARTUP_DELIVERY_SECONDS" "$FINAL_DELIVERY_SECONDS" "$EXECUTION_TIMEOUT_SECONDS" "$ATTEMPT"; do
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || exit 2
done

mkdir -p "$OUTBOX_DIR"
ACTIVE_FILE="$OUTBOX_DIR/$EXECUTION_ID.active"
RUN_LOCK_DIR="$OUTBOX_DIR/$EXECUTION_ID.runlock"
ABORT_FILE="$OUTBOX_DIR/$EXECUTION_ID.abort"
EVENT_FILE="$OUTBOX_DIR/$EXECUTION_ID.jsonl"
LOG_FILE="$OUTBOX_DIR/$EXECUTION_ID.log"
STATE_FILE="$OUTBOX_DIR/$EXECUTION_ID.state.json"
PLAN_FILE="${RUNNER_PLAN_FILE:-$WORK_DIR/execution-plan.json}"
METADATA_FILE="${RUNNER_METADATA_FILE:-}"
RESULT_FILE="${RUNNER_RESULT_FILE:-}"

json_escape() {
  LC_ALL=C tr -d '\000-\010\013\014\016-\037' |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e $'s/\t/\\t/g' -e $'s/\r/\\r/g' |
    awk 'BEGIN { ORS="" } { if (NR > 1) printf "\\n"; printf "%s", $0 }'
}

read_json_object() {
  local file="${1:-}" fallback="${2:-{}}" value
  if [[ -n "$file" && -s "$file" ]]; then
    value="$(jq -c -e 'type == "object"' "$file" 2>/dev/null || true)"
    [[ -z "$value" ]] || { printf '%s' "$value"; return; }
  fi
  printf '%s' "$fallback"
}

current_job_id() {
  local resolved=""
  if [[ -n "$JOB_FILE" && -s "$JOB_FILE" ]]; then
    resolved="$(jq -r '.jobId // empty' "$JOB_FILE" 2>/dev/null || true)"
    [[ -z "$resolved" ]] || { printf '%s' "$resolved"; return; }
  fi
  if [[ -n "${RUNNER_JOB_ID:-}" ]]; then
    printf '%s' "$RUNNER_JOB_ID"
  else
    printf '%s' "$EXECUTION_ID"
  fi
}

next_seq() {
  local seq=0 candidate file
  if [[ -s "$STATE_FILE" ]]; then
    candidate="$(jq -r '.seq // 0' "$STATE_FILE" 2>/dev/null || printf '0')"
    [[ "$candidate" =~ ^[0-9]+$ ]] && (( candidate > seq )) && seq="$candidate"
  fi
  for file in "$EVENT_FILE" "$OUTBOX_DIR/$EXECUTION_ID".*.pending.jsonl; do
    [[ -s "$file" ]] || continue
    candidate="$(jq -s 'map(.seq // 0) | max // 0' "$file" 2>/dev/null || printf '0')"
    [[ "$candidate" =~ ^[0-9]+$ ]] && (( candidate > seq )) && seq="$candidate"
  done
  printf '%s' "$((seq + 1))"
}

last_logs() {
  [[ ! -s "$LOG_FILE" ]] || tail -n 5 "$LOG_FILE" | tail -c 30000 | json_escape
}

record_state() {
  local status="$1" code="$2" message="$3" seq="${4:-0}" tmp
  if [[ "$seq" == "0" && -s "$STATE_FILE" ]]; then
    seq="$(jq -r '.seq // 0' "$STATE_FILE" 2>/dev/null || printf '0')"
  fi
  [[ "$seq" =~ ^[0-9]+$ ]] || seq=0
  tmp="$STATE_FILE.tmp.$$"
  jq -n --arg executionId "$EXECUTION_ID" --arg jobId "$(current_job_id)" \
    --arg status "$status" --arg code "$code" --arg message "$message" \
    --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson seq "$seq" \
    '{schemaVersion:1,executionId:$executionId,jobId:$jobId,status:$status,code:$code,message:$message,seq:$seq,updatedAt:$updatedAt}' \
    > "$tmp" && mv "$tmp" "$STATE_FILE"
  sync -f "$STATE_FILE" 2>/dev/null || true
}

emit_event() {
  local status="$1" phase="$2" code="$3" message="$4"
  local error_code="${5:-0}" error_category="${6:-}" error_message="${7:-}"
  local seq timestamp logs metadata result error job_id
  seq="$(next_seq)"
  timestamp="$(date +%s%3N)"
  logs="$(last_logs)"
  metadata="$(read_json_object "$METADATA_FILE" '{}')"
  job_id="$(current_job_id)"
  result="null"
  error="null"
  [[ "$status" != "COMPLETED" ]] || result="$(read_json_object "$RESULT_FILE" '{}')"
  if [[ "$status" == "FAILED" || "$status" == "CANCELLED" ]]; then
    error="{\"code\":$error_code,\"category\":\"$(printf '%s' "$error_category" | json_escape)\",\"message\":\"$(printf '%s' "$error_message" | json_escape)\"}"
  fi
  printf '{"executionId":"%s","jobId":"%s","attempt":%s,"platform":"%s","platformRunId":"%s","seq":%s,"timestamp":%s,"status":"%s","phase":"%s","code":"%s","message":"%s","logs":"%s","result":%s,"error":%s,"metadata":%s}\n' \
    "$(printf '%s' "$EXECUTION_ID" | json_escape)" "$(printf '%s' "$job_id" | json_escape)" "$ATTEMPT" \
    "$(printf '%s' "$PLATFORM" | json_escape)" "$(printf '%s' "$PLATFORM_RUN_ID" | json_escape)" "$seq" "$timestamp" "$status" \
    "$(printf '%s' "$phase" | json_escape)" "$(printf '%s' "$code" | json_escape)" "$(printf '%s' "$message" | json_escape)" \
    "$logs" "$result" "$error" "$metadata" >> "$EVENT_FILE"
  sync -f "$EVENT_FILE" 2>/dev/null || true
  record_state "$status" "$code" "$message" "$seq"
}

callback_configuration_is_valid() {
  "$ROOT_DIR/runner/dispatcher.sh" --validate-config
}

pending_events_exist() {
  [[ -e "$EVENT_FILE" ]] && return 0
  compgen -G "$OUTBOX_DIR/$EXECUTION_ID.*.pending.jsonl" >/dev/null
}

deliver_until() {
  local seconds="$1" deadline delay=1 now remaining
  deadline=$(( $(date +%s) + seconds ))
  while pending_events_exist; do
    if "$ROOT_DIR/runner/dispatcher.sh" --once --execution-id "$EXECUTION_ID" && ! pending_events_exist; then return 0; fi
    now="$(date +%s)"
    (( now < deadline )) || return 1
    remaining=$((deadline - now))
    (( delay <= remaining )) || delay="$remaining"
    sleep "$delay"
    (( delay < 8 )) && delay=$((delay * 2))
  done
}

acquire_lock() {
  local owner_pid owner_started now owner_file="$RUN_LOCK_DIR/owner"
  if mkdir "$RUN_LOCK_DIR" 2>/dev/null; then printf '%s %s\n' "$$" "$(date +%s)" > "$owner_file"; return 0; fi
  [[ -s "$owner_file" ]] || return 1
  read -r owner_pid owner_started < "$owner_file" || return 1
  [[ "$owner_pid" =~ ^[0-9]+$ && "$owner_started" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$owner_pid" 2>/dev/null && return 1
  now="$(date +%s)"; (( now - owner_started >= STALE_LOCK_SECONDS )) || return 1
  rm -f "$owner_file"; rmdir "$RUN_LOCK_DIR" 2>/dev/null || return 1
  mkdir "$RUN_LOCK_DIR" || return 1
  printf '%s %s\n' "$$" "$now" > "$owner_file"
}

worker_pid=""
lock_acquired=false
terminal_emitted=false

terminate_worker() {
  [[ -n "$worker_pid" ]] || return 0
  kill -TERM -- "-$worker_pid" 2>/dev/null || kill -TERM "$worker_pid" 2>/dev/null || true
  local waited=0
  while kill -0 "$worker_pid" 2>/dev/null && (( waited < 10 )); do sleep 1; waited=$((waited + 1)); done
  kill -KILL -- "-$worker_pid" 2>/dev/null || kill -KILL "$worker_pid" 2>/dev/null || true
}

cleanup() {
  rm -f "$ACTIVE_FILE" "$ABORT_FILE" "$RUN_LOCK_DIR/owner"
  rmdir "$RUN_LOCK_DIR" 2>/dev/null || true
}

on_signal() {
  trap - ERR
  terminate_worker
  if [[ "$terminal_emitted" == false && "$lock_acquired" == true ]]; then
    emit_event "CANCELLED" "cancelled" "JOB_CANCELLED" "Job execution was cancelled." 143 "RUNNER_CANCELLED" "Runner received a termination signal"
    terminal_emitted=true
    rm -f "$ACTIVE_FILE"
    [[ "$REQUIRE_CALLBACK" != "true" ]] || deliver_until "$FINAL_DELIVERY_SECONDS" || true
  fi
  exit 143
}

on_error() {
  local status="$1" line="$2"
  trap - ERR
  terminate_worker
  if [[ "$terminal_emitted" == false && "$lock_acquired" == true ]]; then
    set +e
    emit_event "FAILED" "runner_failed" "RUNNER_INTERNAL_ERROR" "Runner failed before completing the job." "$status" "RUNNER_INTERNAL_ERROR" "Unexpected runner failure near line $line"
    terminal_emitted=true
    rm -f "$ACTIVE_FILE"
    [[ "$REQUIRE_CALLBACK" != "true" ]] || deliver_until "$FINAL_DELIVERY_SECONDS"
  fi
  exit "$status"
}

trap 'on_error $? $LINENO' ERR
trap on_signal INT TERM HUP
trap cleanup EXIT

: > "$LOG_FILE"
acquire_lock || { echo "Execution is already active or its lock is not safely reclaimable." >&2; exit 75; }
lock_acquired=true
record_state "STARTING" "RUNNER_BOOTSTRAP" "Runner bootstrap started."
rm -f "$ABORT_FILE"

if [[ "$REQUIRE_CALLBACK" == "true" ]] && ! callback_configuration_is_valid; then
  emit_event "FAILED" "configuration_refused" "CONFIGURATION_INVALID" "Runner callback configuration is missing or invalid." 78 "RUNNER_CALLBACK_CONFIGURATION_INVALID" "Required callback configuration is unavailable"
  terminal_emitted=true
  exit 78
fi

if [[ ${#PREFLIGHT_COMMAND[@]} -gt 0 ]]; then
  set +e
  "${PREFLIGHT_COMMAND[@]}" >> "$LOG_FILE" 2>&1
  preflight_status=$?
  set -e
  if (( preflight_status != 0 )); then
    emit_event "FAILED" "configuration_refused" "JOB_VALIDATION_FAILED" "Runner refused the job during preparation or validation." "$preflight_status" "RUNNER_PRECHECK_FAILED" "Platform preparation or action preflight failed"
    terminal_emitted=true
    [[ "$REQUIRE_CALLBACK" != "true" ]] || deliver_until "$FINAL_DELIVERY_SECONDS" || true
    exit 78
  fi
fi

if [[ -s "$PLAN_FILE" ]]; then
  planned_timeout="$(jq -r '.timeoutSeconds // empty' "$PLAN_FILE" 2>/dev/null || true)"
  [[ "$planned_timeout" =~ ^[1-9][0-9]*$ ]] || {
    emit_event "FAILED" "configuration_refused" "JOB_VALIDATION_FAILED" "Runner refused the job because its execution plan is invalid." 2 "RUNNER_PRECHECK_FAILED" "Execution plan has no valid timeout"
    terminal_emitted=true
    [[ "$REQUIRE_CALLBACK" != "true" ]] || deliver_until "$FINAL_DELIVERY_SECONDS" || true
    exit 78
  }
  (( planned_timeout <= 86400 )) || {
    emit_event "FAILED" "configuration_refused" "JOB_VALIDATION_FAILED" "Runner refused the job because its execution plan is invalid." 2 "RUNNER_PRECHECK_FAILED" "Execution plan timeout exceeds the Runner maximum"
    terminal_emitted=true
    [[ "$REQUIRE_CALLBACK" != "true" ]] || deliver_until "$FINAL_DELIVERY_SECONDS" || true
    exit 78
  }
  EXECUTION_TIMEOUT_SECONDS="$planned_timeout"
fi

emit_event "STARTED" "starting" "RUNNER_STARTED" "Runner accepted the job and is starting the worker."
if [[ "$REQUIRE_CALLBACK" == "true" ]] && ! deliver_until "$STARTUP_DELIVERY_SECONDS"; then
  emit_event "FAILED" "configuration_refused" "CALLBACK_UNAVAILABLE" "Worker was not started because startup acknowledgement was unavailable." 78 "RUNNER_CALLBACK_UNAVAILABLE" "Backend did not acknowledge runner startup"
  terminal_emitted=true
  deliver_until "$FINAL_DELIVERY_SECONDS" || true
  exit 78
fi

touch "$ACTIVE_FILE"
if command -v setsid >/dev/null 2>&1; then setsid "${WORKER_COMMAND[@]}" >> "$LOG_FILE" 2>&1 & else "${WORKER_COMMAND[@]}" >> "$LOG_FILE" 2>&1 & fi
worker_pid=$!
processed_lines=0
cancelled=false
timed_out=false
execution_deadline=$(( $(date +%s) + EXECUTION_TIMEOUT_SECONDS ))

while kill -0 "$worker_pid" 2>/dev/null; do
  total_lines="$(wc -l < "$LOG_FILE" | tr -d ' ')"
  if (( total_lines > processed_lines )); then
    tail -n "+$((processed_lines + 1))" "$LOG_FILE"
    processed_lines=$total_lines
  fi
  if [[ -e "$ABORT_FILE" ]]; then cancelled=true; terminate_worker; break; fi
  if (( $(date +%s) >= execution_deadline )); then timed_out=true; terminate_worker; break; fi
  sleep 1
done

set +e
wait "$worker_pid"
worker_status=$?
set -e
total_lines="$(wc -l < "$LOG_FILE" | tr -d ' ')"
(( total_lines <= processed_lines )) || tail -n "+$((processed_lines + 1))" "$LOG_FILE"
rm -f "$ACTIVE_FILE"

if [[ "$cancelled" == true ]]; then
  emit_event "CANCELLED" "cancelled" "JOB_CANCELLED" "Job execution was cancelled." 143 "RUNNER_CANCELLED" "Execution cancelled by backend"
  final_status=143
elif [[ "$timed_out" == true ]]; then
  emit_event "FAILED" "failed" "JOB_TIMED_OUT" "Job exceeded its execution time limit." 124 "RUNNER_TIMEOUT" "Worker exceeded ${EXECUTION_TIMEOUT_SECONDS} seconds"
  final_status=124
elif (( worker_status == 0 )); then
  emit_event "COMPLETED" "completed" "JOB_COMPLETED" "Job completed successfully."
  final_status=0
else
  emit_event "FAILED" "failed" "JOB_FAILED" "Job failed during worker execution." "$worker_status" "RUNNER_FAILED" "Worker exited with status $worker_status"
  final_status=$worker_status
fi
terminal_emitted=true
if [[ "$REQUIRE_CALLBACK" == "true" ]] && ! deliver_until "$FINAL_DELIVERY_SECONDS"; then
  record_state "FAILED" "TERMINAL_DELIVERY_PENDING" "Terminal result remains pending in the outbox."
  exit 74
fi
exit "$final_status"
