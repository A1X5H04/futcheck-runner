#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${FUTCHECK_WORK_DIR:-${RUNNER_TEMP:-/tmp}/futcheck-work}"

echo "[ACTION] executing_action"
"$ROOT_DIR/runner/execute.sh" \
  --job "$WORK_DIR/job.json" \
  --input "$WORK_DIR/input" \
  --output "$WORK_DIR/output"

echo "[ACTION] publishing_artifact"
"$ROOT_DIR/adapters/github/prepare-result.sh"
