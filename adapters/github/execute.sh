#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${FUTCHECK_WORK_DIR:-${RUNNER_TEMP:-/tmp}/futcheck-work}"

"$ROOT_DIR/adapters/github/prepare-job.sh"
JOB_ID="$(cat "$WORK_DIR/job_id.txt")"
export RUNNER_WORK_DIR="$WORK_DIR"
export RUNNER_METADATA_FILE="$WORK_DIR/runner_metadata.json"
export RUNNER_RESULT_FILE="$WORK_DIR/job_result.json"
export RUNNER_TOKEN="${RUNNER_TOKEN:-${FUTCHECK_JOB_TOKEN:-}}"
if [[ -z "${FUTCHECK_CALLBACK_URL:-}" && -n "${FUTCHECK_JOB_API_URL:-}" ]]; then
  if [[ "$FUTCHECK_JOB_API_URL" =~ /jobs/?$ ]] || [[ "$FUTCHECK_JOB_API_URL" =~ /jobs/ ]]; then
    export FUTCHECK_CALLBACK_URL="${FUTCHECK_JOB_API_URL%/jobs*}/webhook/callback"
  else
    export FUTCHECK_CALLBACK_URL="${FUTCHECK_JOB_API_URL%/}/api/workflow/runner/webhook/callback"
  fi
fi

"$ROOT_DIR/runner/supervisor.sh" "$JOB_ID" \
  "$ROOT_DIR/adapters/github/run-action.sh"
