#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOB_FILE="${1:-$ROOT_DIR/examples/jobs/render-svg.json}"
EXECUTION_ID="${RUNNER_EXECUTION_ID:-}"

if [[ -z "$EXECUTION_ID" ]]; then
  seed="${JOB_FILE}:$(date +%s%N):${RANDOM}:${RANDOM}"
  hash="$(printf '%s' "$seed" | sha256sum | awk '{print $1}')"
  EXECUTION_ID="${hash:0:8}-${hash:8:4}-4${hash:13:3}-8${hash:17:3}-${hash:20:12}"
fi

WORK_DIR="${FUTCHECK_WORK_DIR:-$ROOT_DIR/.work/$EXECUTION_ID}"

mkdir -p "$WORK_DIR/input" "$WORK_DIR/output"
export RUNNER_WORK_DIR="$WORK_DIR"
export RUNNER_REQUIRE_CALLBACK="${RUNNER_REQUIRE_CALLBACK:-false}"
export RUNNER_RESULT_FILE="${RUNNER_RESULT_FILE:-$WORK_DIR/output/result.json}"
printf 'Runner work directory: %s\n' "$WORK_DIR"
exec bash "$ROOT_DIR/runner/entrypoint.sh" \
  --execution-id "$EXECUTION_ID" \
  --job "$JOB_FILE" \
  --input "$WORK_DIR/input" \
  --output "$WORK_DIR/output"
