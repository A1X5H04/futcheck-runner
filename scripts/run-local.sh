#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOB_FILE="${1:-$ROOT_DIR/examples/jobs/render-svg.json}"
WORK_DIR="${FUTCHECK_WORK_DIR:-$ROOT_DIR/.work}"

mkdir -p "$WORK_DIR/input" "$WORK_DIR/output"
exec "$ROOT_DIR/runner/execute.sh" \
  --job "$JOB_FILE" \
  --input "$WORK_DIR/input" \
  --output "$WORK_DIR/output"
