#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${FUTCHECK_WORK_DIR:-${RUNNER_TEMP:-/tmp}/futcheck-work}"

"$ROOT_DIR/adapters/github/prepare-job.sh"
"$ROOT_DIR/runner/execute.sh" \
  --job "$WORK_DIR/job.json" \
  --input "$WORK_DIR/input" \
  --output "$WORK_DIR/output"

# If running outside GitHub Actions (e.g. locally), report result immediately
if [[ -z "${GITHUB_ACTIONS:-}" ]]; then
  "$ROOT_DIR/adapters/github/report-result.sh" 0 || true
fi
