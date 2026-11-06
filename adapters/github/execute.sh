#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${FUTCHECK_WORK_DIR:-${RUNNER_TEMP:-/tmp}/futcheck-work}"
EXECUTION_ID="${FUTCHECK_EXECUTION_ID:-}"
[[ "$EXECUTION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] || {
  echo "FUTCHECK_EXECUTION_ID must be supplied as a UUID by the triggerer." >&2
  exit 2
}

export RUNNER_WORK_DIR="$WORK_DIR"
export RUNNER_METADATA_FILE="$WORK_DIR/runner_metadata.json"
export RUNNER_RESULT_FILE="$WORK_DIR/output/result.json"
export RUNNER_JOB_ID="${FUTCHECK_JOB_KEY:-${FUTCHECK_JOB_ID:-$EXECUTION_ID}}"
export RUNNER_ATTEMPT="${FUTCHECK_ATTEMPT:-1}"
export RUNNER_PLATFORM="github"
export RUNNER_PLATFORM_RUN_ID="${GITHUB_RUN_ID:-}"
export RUNNER_TOKEN="${RUNNER_TOKEN:-${FUTCHECK_JOB_TOKEN:-}}"
export RUNNER_REQUIRE_CALLBACK="true"
export RUNNER_ALLOWED_CALLBACK_HOSTS="${FUTCHECK_ALLOWED_CALLBACK_HOSTS:-${FUTCHECK_ALLOWED_JOB_HOSTS:-}}"
export RUNNER_CONTROL_URL="${FUTCHECK_CONTROL_URL:-}"
if [[ -z "${FUTCHECK_CALLBACK_URL:-}" && -n "${FUTCHECK_JOB_API_URL:-}" ]]; then
  if [[ "$FUTCHECK_JOB_API_URL" =~ /jobs/?$ ]]; then
    export FUTCHECK_CALLBACK_URL="${FUTCHECK_JOB_API_URL%/jobs*}/webhook/callback"
  else
    export FUTCHECK_CALLBACK_URL="${FUTCHECK_JOB_API_URL%/}/api/workflow/runner/webhook/callback"
  fi
fi

bash "$ROOT_DIR/runner/entrypoint.sh" \
  --execution-id "$EXECUTION_ID" \
  --job "$WORK_DIR/job.json" \
  --input "$WORK_DIR/input" \
  --output "$WORK_DIR/output" \
  --prepare "$ROOT_DIR/adapters/github/prepare-job.sh"
