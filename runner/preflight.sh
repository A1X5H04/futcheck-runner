#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOB_FILE=""
INPUT_DIR=""
OUTPUT_DIR=""
PREPARE_COMMAND=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job) JOB_FILE="${2:?Missing value for --job}"; shift 2 ;;
    --input) INPUT_DIR="${2:?Missing value for --input}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:?Missing value for --output}"; shift 2 ;;
    --prepare) PREPARE_COMMAND="${2:?Missing value for --prepare}"; shift 2 ;;
    *) echo "Unknown preflight argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$PREPARE_COMMAND" ]]; then
  [[ -x "$PREPARE_COMMAND" ]] || { echo "Platform prepare command is not executable." >&2; exit 2; }
  "$PREPARE_COMMAND"
fi

[[ -f "$JOB_FILE" ]] || { echo "Platform did not materialize the job file." >&2; exit 2; }
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

exec "$ROOT_DIR/runner/execute.sh" --preflight \
  --job "$JOB_FILE" --input "$INPUT_DIR" --output "$OUTPUT_DIR"
