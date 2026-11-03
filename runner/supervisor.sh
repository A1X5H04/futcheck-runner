#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${RUNNER_WORK_DIR:-${FUTCHECK_WORK_DIR:-$ROOT_DIR/.work}}"
OUTBOX_DIR="$WORK_DIR/outbox"
EVENT_INTERVAL="${RUNNER_EVENT_INTERVAL_SECONDS:-15}"
JOB_ID="${1:-}"

usage() {
  echo "Usage: runner/supervisor.sh <job-uuid> <command> [args...]" >&2
}

[[ "$JOB_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] || {
  echo "The runner job id must be a UUID." >&2
  usage
  exit 2
}
shift
[[ $# -gt 0 ]] || { usage; exit 2; }
[[ "$EVENT_INTERVAL" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid runner event interval." >&2; exit 2; }

mkdir -p "$OUTBOX_DIR"
ACTIVE_FILE="$OUTBOX_DIR/$JOB_ID.active"
ABORT_FILE="$OUTBOX_DIR/$JOB_ID.abort"
EVENT_FILE="$OUTBOX_DIR/$JOB_ID.jsonl"
LOG_FILE="$OUTBOX_DIR/$JOB_ID.log"
SEQ_FILE="$OUTBOX_DIR/$JOB_ID.seq"
CHUNK_FILE="$OUTBOX_DIR/$JOB_ID.chunk"
METADATA_FILE="${RUNNER_METADATA_FILE:-}"
RESULT_FILE="${RUNNER_RESULT_FILE:-}"

json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' -e 's//\\r/g' |
    awk 'BEGIN { ORS="" } { if (NR > 1) printf "\\n"; printf "%s", $0 }'
}

# Override the basic encoder so raw control bytes can never poison a JSONL batch.
json_escape() {
  LC_ALL=C tr -d '\000-\010\013\014\016-\037' |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e $'s/\t/\\\\t/g' -e $'s/\r/\\\\r/g' |
    awk 'BEGIN { ORS="" } { if (NR > 1) printf "\\n"; printf "%s", $0 }'
}

read_json_object() {
  local file="${1:-}"
  local fallback="${2-}"
  [[ -n "$fallback" ]] || fallback='{}'
  if [[ -n "$file" && -s "$file" ]]; then
    local value
    value="$(tr -d '\n\r' < "$file")"
    if [[ "$value" == \{*\} ]]; then
      printf '%s' "$value"
      return
    fi
  fi
  printf '%s' "$fallback"
}

next_seq() {
  local seq=0
  if [[ -s "$SEQ_FILE" ]]; then read -r seq < "$SEQ_FILE" || seq=0; fi
  [[ "$seq" =~ ^[0-9]+$ ]] || seq=0
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$SEQ_FILE"
  printf '%s' "$seq"
}

last_logs() {
  if [[ -s "$LOG_FILE" ]]; then tail -n 5 "$LOG_FILE" | tail -c 30000 | json_escape; fi
}

emit_event() {
  local status="$1"
  local phase="$2"
  local error_code="${3:-0}"
  local error_category="${4:-}"
  local error_message="${5:-}"
  local seq timestamp logs metadata result error
  seq="$(next_seq)"
  timestamp="$(date +%s%3N)"
  logs="$(last_logs)"
  metadata="$(read_json_object "$METADATA_FILE" '{}')"
  result="null"
  error="null"
  if [[ "$status" == "COMPLETED" ]]; then
    result="$(read_json_object "$RESULT_FILE" '{}')"
  elif [[ "$status" == "FAILED" || "$status" == "CANCELLED" ]]; then
    error="{\"code\":$error_code,\"category\":\"$(printf '%s' "$error_category" | json_escape)\",\"message\":\"$(printf '%s' "$error_message" | json_escape)\"}"
  fi
  printf '{"jobId":"%s","seq":%s,"timestamp":%s,"status":"%s","phase":"%s","logs":"%s","result":%s,"error":%s,"metadata":%s}\n' \
    "$JOB_ID" "$seq" "$timestamp" "$status" \
    "$(printf '%s' "$phase" | json_escape)" "$logs" "$result" "$error" "$metadata" >> "$EVENT_FILE"
}

worker_pid=""
cleanup() {
  rm -f "$ACTIVE_FILE" "$ABORT_FILE" "$LOG_FILE" "$CHUNK_FILE"
}
terminate_worker() {
  [[ -n "$worker_pid" ]] || return
  kill -TERM -- "-$worker_pid" 2>/dev/null || kill -TERM "$worker_pid" 2>/dev/null || true
  local waited=0
  while kill -0 "$worker_pid" 2>/dev/null && (( waited < 10 )); do
    sleep 1
    waited=$((waited + 1))
  done
  kill -KILL -- "-$worker_pid" 2>/dev/null || kill -KILL "$worker_pid" 2>/dev/null || true
}
on_signal() {
  terminate_worker
  emit_event "CANCELLED" "cancelled" 143 "RUNNER_CANCELLED" "Runner received a termination signal"
  cleanup
  exit 143
}
trap on_signal INT TERM HUP
trap cleanup EXIT

: > "$LOG_FILE"
touch "$ACTIVE_FILE"
rm -f "$ABORT_FILE"
nohup "$ROOT_DIR/runner/dispatcher.sh" </dev/null >/dev/null 2>&1 &
emit_event "STARTED" "starting"

if command -v setsid >/dev/null 2>&1; then
  setsid "$@" >> "$LOG_FILE" 2>&1 &
else
  "$@" >> "$LOG_FILE" 2>&1 &
fi
worker_pid=$!
phase="running"
processed_lines=0
last_event_at="$(date +%s)"
cancelled=false

while kill -0 "$worker_pid" 2>/dev/null; do
  total_lines="$(wc -l < "$LOG_FILE" | tr -d ' ')"
  if (( total_lines > processed_lines )); then
    tail -n "+$((processed_lines + 1))" "$LOG_FILE" > "$CHUNK_FILE"
    while IFS= read -r line || [[ -n "$line" ]]; do
      printf '%s\n' "$line"
      if [[ "$line" == "[ACTION] "* ]]; then
        phase="${line#\[ACTION\] }"
        phase="${phase:0:256}"
        emit_event "RUNNING" "$phase"
        last_event_at="$(date +%s)"
      fi
    done < "$CHUNK_FILE"
    processed_lines=$total_lines
  fi

  if [[ -e "$ABORT_FILE" ]]; then
    cancelled=true
    terminate_worker
    break
  fi

  now="$(date +%s)"
  if (( now - last_event_at >= EVENT_INTERVAL )); then
    emit_event "RUNNING" "$phase"
    last_event_at=$now
  fi
  sleep 1
done

set +e
wait "$worker_pid"
worker_status=$?
set -e

total_lines="$(wc -l < "$LOG_FILE" | tr -d ' ')"
if (( total_lines > processed_lines )); then
  tail -n "+$((processed_lines + 1))" "$LOG_FILE" > "$CHUNK_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\n' "$line"; done < "$CHUNK_FILE"
fi

if [[ "$cancelled" == true ]]; then
  emit_event "CANCELLED" "cancelled" 143 "RUNNER_CANCELLED" "Execution cancelled by backend"
  final_status=143
elif (( worker_status == 0 )); then
  emit_event "COMPLETED" "completed"
  final_status=0
else
  emit_event "FAILED" "failed" "$worker_status" "RUNNER_FAILED" "Worker exited with status $worker_status"
  final_status=$worker_status
fi

rm -f "$ACTIVE_FILE"
if [[ -n "${BACKEND_STATUS_URL:-${FUTCHECK_CALLBACK_URL:-}}" ]]; then
  deadline=$(( $(date +%s) + 45 ))
  while (( $(date +%s) < deadline )); do
    pending=false
    for pending_file in "$OUTBOX_DIR/$JOB_ID.jsonl" "$OUTBOX_DIR/$JOB_ID.lock.jsonl"; do
      [[ -e "$pending_file" ]] && pending=true
    done
    [[ "$pending" == false ]] && break
    sleep 1
  done
fi
exit "$final_status"
