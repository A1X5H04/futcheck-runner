#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
JOB_ID="11111111-1111-4111-8111-111111111111"

RUNNER_WORK_DIR="$TEMP_DIR" RUNNER_EVENT_INTERVAL_SECONDS=1 \
  "$ROOT_DIR/runner/supervisor.sh" "$JOB_ID" bash -c \
  'printf "[ACTION] rendering_frames\nline with \"quotes\", \\slashes and\ta tab\n"; sleep 1'

jq -e -s '
  length >= 3
  and .[0].status == "STARTED"
  and any(.[]; .status == "RUNNING" and .phase == "rendering_frames")
  and .[-1].status == "COMPLETED"
  and .[-1].result == {}
  and ([.[].seq] == ([.[].seq] | sort))
' "$TEMP_DIR/outbox/$JOB_ID.jsonl" >/dev/null

if RUNNER_WORK_DIR="$TEMP_DIR/failure" \
  "$ROOT_DIR/runner/supervisor.sh" "$JOB_ID" bash -c 'echo boom; exit 7'; then
  echo "Expected the failing worker status to be preserved." >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 7 ]]
fi
jq -e -s '.[-1].status == "FAILED" and .[-1].error.code == 7' \
  "$TEMP_DIR/failure/outbox/$JOB_ID.jsonl" >/dev/null

echo "Supervisor lifecycle tests passed."
