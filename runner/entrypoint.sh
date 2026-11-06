#!/usr/bin/env bash
set -Eeuo pipefail

# Generic OS entrypoint. Adapters stage the standard work contract, then call
# this file; actions never need to know which adapter launched them.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXECUTION_ID=""
JOB_FILE=""
INPUT_DIR=""
OUTPUT_DIR=""
PREPARE_COMMAND=""

usage() {
  echo "Usage: runner/entrypoint.sh --execution-id <uuid> --job <job.json> [--input <directory>] [--output <directory>] [--prepare <executable>]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execution-id) EXECUTION_ID="${2:?Missing value for --execution-id}"; shift 2 ;;
    --job) JOB_FILE="${2:?Missing value for --job}"; shift 2 ;;
    --input) INPUT_DIR="${2:?Missing value for --input}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:?Missing value for --output}"; shift 2 ;;
    --prepare) PREPARE_COMMAND="${2:?Missing value for --prepare}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$EXECUTION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] || { echo "--execution-id must be a UUID." >&2; exit 2; }
[[ -n "$JOB_FILE" ]] || { usage; exit 2; }

WORK_DIR="${RUNNER_WORK_DIR:-${FUTCHECK_WORK_DIR:-$ROOT_DIR/.work}}"
INPUT_DIR="${INPUT_DIR:-$(dirname "$JOB_FILE")/input}"
OUTPUT_DIR="${OUTPUT_DIR:-$(dirname "$JOB_FILE")/output}"
CONTROL_DIR="${RUNNER_CONTROL_DIR:-$WORK_DIR/control}"
mkdir -p "$CONTROL_DIR"
cp "$ROOT_DIR/runner/worker-api.sh" "$CONTROL_DIR/runner-api.sh"
chmod 0444 "$CONTROL_DIR/runner-api.sh"
: > "$CONTROL_DIR/messages.jsonl"

ACTION_ARGS=(--job "$JOB_FILE" --input "$INPUT_DIR" --output "$OUTPUT_DIR")
PREFLIGHT_ARGS=("${ACTION_ARGS[@]}")
[[ -n "$PREPARE_COMMAND" ]] && PREFLIGHT_ARGS+=(--prepare "$PREPARE_COMMAND")

export RUNNER_EXECUTION_ID="$EXECUTION_ID"
export RUNNER_JOB_FILE="$JOB_FILE"
export RUNNER_INPUT_DIR="$INPUT_DIR"
export RUNNER_OUTPUT_DIR="$OUTPUT_DIR"
export RUNNER_CONTROL_DIR="$CONTROL_DIR"
export RUNNER_MESSAGE_FILE="$CONTROL_DIR/messages.jsonl"
export RUNNER_PLAN_FILE="${RUNNER_PLAN_FILE:-$WORK_DIR/execution-plan.json}"
export RUNNER_RESULT_FILE="${RUNNER_RESULT_FILE:-$OUTPUT_DIR/result.json}"

exec "$ROOT_DIR/runner/supervisor.sh" "$EXECUTION_ID" \
  --preflight bash "$ROOT_DIR/runner/preflight.sh" "${PREFLIGHT_ARGS[@]}" -- \
  "$ROOT_DIR/runner/execute.sh" "${ACTION_ARGS[@]}"
