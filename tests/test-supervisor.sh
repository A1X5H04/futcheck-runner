#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
JOB_ID="11111111-1111-4111-8111-111111111111"

RUNNER_WORK_DIR="$TEMP_DIR" \
  "$ROOT_DIR/runner/supervisor.sh" "$JOB_ID" bash -c \
  'printf "[ACTION] rendering_frames\nline with \"quotes\", \\slashes and\ta tab\n"; sleep 1'

jq -e -s '
  length == 2
  and .[0].status == "STARTED" and .[0].code == "RUNNER_STARTED"
  and .[-1].status == "COMPLETED" and .[-1].code == "JOB_COMPLETED"
  and .[0].executionId == "11111111-1111-4111-8111-111111111111"
  and .[-1].result == {}
  and ([.[].seq] == [1, 2])
' "$TEMP_DIR/outbox/$JOB_ID.jsonl" >/dev/null
jq -e '.seq == 2 and .code == "JOB_COMPLETED"' "$TEMP_DIR/outbox/$JOB_ID.state.json" >/dev/null

if RUNNER_WORK_DIR="$TEMP_DIR/failure" \
  "$ROOT_DIR/runner/supervisor.sh" "$JOB_ID" bash -c 'echo boom; exit 7'; then
  echo "Expected the failing worker status to be preserved." >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 7 ]]
fi
jq -e -s '.[-1].status == "FAILED" and .[-1].code == "JOB_FAILED" and .[-1].error.code == 7' \
  "$TEMP_DIR/failure/outbox/$JOB_ID.jsonl" >/dev/null

if RUNNER_WORK_DIR="$TEMP_DIR/preflight-failure" \
  "$ROOT_DIR/runner/supervisor.sh" "$JOB_ID" --preflight bash -c 'exit 2' -- bash -c 'exit 0'; then
  echo "Expected a failed preflight to refuse the worker." >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 78 ]]
fi
jq -e -s '.[-1].status == "FAILED" and .[-1].code == "JOB_VALIDATION_FAILED"' \
  "$TEMP_DIR/preflight-failure/outbox/$JOB_ID.jsonl" >/dev/null

mkdir -p "$TEMP_DIR/stale-lock/outbox/$JOB_ID.runlock"
printf '99999999 0\n' > "$TEMP_DIR/stale-lock/outbox/$JOB_ID.runlock/owner"
RUNNER_WORK_DIR="$TEMP_DIR/stale-lock" RUNNER_STALE_LOCK_SECONDS=1 \
  "$ROOT_DIR/runner/supervisor.sh" "$JOB_ID" bash -c 'exit 0'
jq -e -s '.[-1].status == "COMPLETED"' \
  "$TEMP_DIR/stale-lock/outbox/$JOB_ID.jsonl" >/dev/null
[[ ! -d "$TEMP_DIR/stale-lock/outbox/$JOB_ID.runlock" ]]

if RUNNER_WORK_DIR="$TEMP_DIR/timeout" RUNNER_EXECUTION_TIMEOUT_SECONDS=1 \
  "$ROOT_DIR/runner/supervisor.sh" "$JOB_ID" bash -c 'sleep 5'; then
  echo "Expected the supervisor to terminate an overlong worker." >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 124 ]]
fi
jq -e -s '.[-1].status == "FAILED" and .[-1].code == "JOB_TIMED_OUT"' \
  "$TEMP_DIR/timeout/outbox/$JOB_ID.jsonl" >/dev/null

echo "Supervisor lifecycle tests passed."
