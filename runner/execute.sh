#!/usr/bin/env bash
set -Eeuo pipefail

# Generic action router. Runtime-specific behavior belongs in runner/drivers/.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOB_FILE=""
INPUT_DIR=""
OUTPUT_DIR=""
OPERATION="execute"

usage() {
  echo "Usage: runner/execute.sh --job <job.json> [--input <dir>] [--output <dir>] [--validate-only|--preflight]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job) JOB_FILE="${2:?Missing value for --job}"; shift 2 ;;
    --input) INPUT_DIR="${2:?Missing value for --input}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:?Missing value for --output}"; shift 2 ;;
    --validate-only) [[ "$OPERATION" == "execute" ]] || { usage; exit 2; }; OPERATION="validate"; shift ;;
    --preflight) [[ "$OPERATION" == "execute" ]] || { usage; exit 2; }; OPERATION="preflight"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$JOB_FILE" ]] || { usage; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 2; }
command -v realpath >/dev/null 2>&1 || { echo "realpath is required." >&2; exit 2; }

JOB_FILE="$(realpath "$JOB_FILE")"
[[ -f "$JOB_FILE" ]] || { echo "Job file not found: $JOB_FILE" >&2; exit 2; }
INPUT_DIR="$(realpath -m "${INPUT_DIR:-$(dirname "$JOB_FILE")/input}")"
OUTPUT_DIR="$(realpath -m "${OUTPUT_DIR:-$(dirname "$JOB_FILE")/output}")"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

jq -e '
  type == "object"
  and .schemaVersion == 1
  and ((keys - ["schemaVersion","jobId","action","actionVersion","payload","metadata"]) | length == 0)
  and (.jobId | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"))
  and (.action | type == "string" and test("^(?:[a-z][a-z0-9-]*\\.[a-z][a-z0-9-]*|[a-z][a-z0-9_-]*)$"))
  and (.actionVersion | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$"))
  and (.payload | type == "object")
  and ((.metadata // {}) | type == "object")
' "$JOB_FILE" >/dev/null || { echo "Invalid job envelope." >&2; exit 2; }

ACTION_ID="$(jq -r '.action' "$JOB_FILE")"
ACTION_VERSION="$(jq -r '.actionVersion' "$JOB_FILE")"
ACTION_MANIFEST=""
for candidate in "$ROOT_DIR"/actions/*/action.json; do
  [[ -f "$candidate" ]] || continue
  if [[ "$(jq -r '.id // empty' "$candidate")" == "$ACTION_ID" ]]; then
    [[ -z "$ACTION_MANIFEST" ]] || { echo "Duplicate action id: $ACTION_ID" >&2; exit 2; }
    ACTION_MANIFEST="$candidate"
  fi
done
[[ -n "$ACTION_MANIFEST" ]] || { echo "Unknown action: $ACTION_ID" >&2; exit 2; }
[[ "$(jq -r '.version // empty' "$ACTION_MANIFEST")" == "$ACTION_VERSION" ]] || {
  echo "Action version mismatch for $ACTION_ID." >&2
  exit 2
}

SELECTOR="$(jq -r '.execution.selector // empty' "$ACTION_MANIFEST")"
VARIANT="$(jq -r '.execution.defaultVariant // empty' "$ACTION_MANIFEST")"
if [[ -n "$SELECTOR" ]]; then
  selected="$(jq -r --arg selector "$SELECTOR" 'getpath($selector | split(".")) // empty' "$JOB_FILE")"
  [[ -z "$selected" || "$selected" == "null" ]] || VARIANT="$selected"
fi
[[ -n "$VARIANT" ]] || { echo "No execution variant selected for $ACTION_ID." >&2; exit 2; }
jq -e --arg variant "$VARIANT" '.execution.variants[$variant] | type == "object"' "$ACTION_MANIFEST" >/dev/null || {
  echo "Unsupported execution variant '$VARIANT' for $ACTION_ID." >&2
  exit 2
}

DRIVER="$(jq -r --arg variant "$VARIANT" '.execution.variants[$variant].driver // empty' "$ACTION_MANIFEST")"
[[ "$DRIVER" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo "Invalid or missing execution driver." >&2; exit 2; }
DRIVER_FILE="$ROOT_DIR/runner/drivers/$DRIVER.sh"
[[ -f "$DRIVER_FILE" ]] || { echo "Execution driver is unavailable: $DRIVER" >&2; exit 2; }
TIMEOUT_SECONDS="$(jq -r --arg variant "$VARIANT" '.execution.variants[$variant].resources.timeoutSeconds // empty' "$ACTION_MANIFEST")"
MAX_INPUT_BYTES="$(jq -r --arg variant "$VARIANT" '.execution.variants[$variant].resources.maxInputBytes // empty' "$ACTION_MANIFEST")"
MAX_OUTPUT_BYTES="$(jq -r --arg variant "$VARIANT" '.execution.variants[$variant].resources.maxOutputBytes // empty' "$ACTION_MANIFEST")"
for limit in "$TIMEOUT_SECONDS" "$MAX_INPUT_BYTES" "$MAX_OUTPUT_BYTES"; do
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "Action variant has an invalid execution limit." >&2; exit 2; }
done
(( TIMEOUT_SECONDS <= 86400 )) || { echo "Action timeout exceeds the Runner maximum." >&2; exit 2; }

command -v du >/dev/null 2>&1 || { echo "du is required." >&2; exit 2; }
INPUT_BYTES="$(du -sb "$INPUT_DIR" | awk '{print $1}')"
(( INPUT_BYTES <= MAX_INPUT_BYTES )) || { echo "Input exceeds the action byte limit." >&2; exit 2; }

if [[ -n "${RUNNER_PLAN_FILE:-}" ]]; then
  mkdir -p "$(dirname "$RUNNER_PLAN_FILE")"
  plan_tmp="$RUNNER_PLAN_FILE.tmp.$$"
  jq -n --arg action "$ACTION_ID" --arg version "$ACTION_VERSION" --arg variant "$VARIANT" \
    --arg driver "$DRIVER" --argjson timeoutSeconds "$TIMEOUT_SECONDS" \
    --argjson maxInputBytes "$MAX_INPUT_BYTES" --argjson maxOutputBytes "$MAX_OUTPUT_BYTES" \
    '{schemaVersion:1,action:$action,actionVersion:$version,variant:$variant,driver:$driver,timeoutSeconds:$timeoutSeconds,maxInputBytes:$maxInputBytes,maxOutputBytes:$maxOutputBytes}' \
    > "$plan_tmp"
  mv "$plan_tmp" "$RUNNER_PLAN_FILE"
fi

export RUNNER_ROOT_DIR="$ROOT_DIR"
export RUNNER_JOB_FILE="$JOB_FILE"
export RUNNER_INPUT_DIR="$INPUT_DIR"
export RUNNER_OUTPUT_DIR="$OUTPUT_DIR"
export RUNNER_ACTION_ID="$ACTION_ID"
export RUNNER_ACTION_VERSION="$ACTION_VERSION"
export RUNNER_ACTION_MANIFEST="$ACTION_MANIFEST"
export RUNNER_ACTION_DIR="$(dirname "$ACTION_MANIFEST")"
export RUNNER_ACTION_VARIANT="$VARIANT"

bash "$DRIVER_FILE" "$OPERATION"
driver_status=$?
(( driver_status == 0 )) || exit "$driver_status"

[[ "$OPERATION" == "execute" ]] || exit 0
OUTPUT_BYTES="$(du -sb "$OUTPUT_DIR" | awk '{print $1}')"
(( OUTPUT_BYTES <= MAX_OUTPUT_BYTES )) || { echo "Output exceeds the action byte limit." >&2; exit 3; }
MANIFEST_FILE="$OUTPUT_DIR/manifest.json"
[[ -f "$MANIFEST_FILE" ]] || { echo "Worker did not produce manifest.json." >&2; exit 3; }
bash "$ROOT_DIR/runner/validate-result.sh" "$JOB_FILE" "$MANIFEST_FILE" "$OUTPUT_DIR" "$MAX_OUTPUT_BYTES"
