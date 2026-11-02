#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOB_FILE=""
INPUT_DIR=""
OUTPUT_DIR=""

usage() {
  cat <<'USAGE'
Usage:
  runner/execute.sh --job <job.json> [--input <directory>] [--output <directory>]

The executor reads the job envelope, finds the matching action.json, selects
its execution variant, builds that variant's Docker image, and runs it with
/work/job.json, /work/input, and /work/output mounted.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job) JOB_FILE="${2:?Missing value for --job}"; shift 2 ;;
    --input) INPUT_DIR="${2:?Missing value for --input}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:?Missing value for --output}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$JOB_FILE" ]] || { echo "--job is required." >&2; usage >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "Docker CLI is required." >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 2; }
command -v realpath >/dev/null 2>&1 || { echo "realpath is required." >&2; exit 2; }

JOB_FILE="$(realpath "$JOB_FILE")"
[[ -f "$JOB_FILE" ]] || { echo "Job file not found: $JOB_FILE" >&2; exit 2; }
INPUT_DIR="$(realpath -m "${INPUT_DIR:-$(dirname "$JOB_FILE")/input}")"
OUTPUT_DIR="$(realpath -m "${OUTPUT_DIR:-$(dirname "$JOB_FILE")/output}")"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

jq -e 'type == "object" and .schemaVersion == 1 and (.jobId | type == "string" and length > 0) and (.action | type == "string" and length > 0) and (.actionVersion | type == "string" and length > 0) and (.payload | type == "object")' "$JOB_FILE" >/dev/null \
  || { echo "Invalid job envelope. See contracts/v1/job.schema.json." >&2; exit 2; }

JOB_ID="$(jq -r '.jobId' "$JOB_FILE")"
ACTION_ID="$(jq -r '.action' "$JOB_FILE")"
ACTION_VERSION="$(jq -r '.actionVersion' "$JOB_FILE")"

ACTION_MANIFEST=""
for candidate in "$ROOT_DIR"/actions/*/action.json; do
  [[ -f "$candidate" ]] || continue
  candidate_id="$(jq -r '.id // empty' "$candidate")"
  if [[ "$candidate_id" == "$ACTION_ID" ]]; then
    if [[ -n "$ACTION_MANIFEST" ]]; then
      echo "Duplicate action id in action manifests: $ACTION_ID" >&2
      exit 2
    fi
    ACTION_MANIFEST="$candidate"
  fi
done

if [[ -z "$ACTION_MANIFEST" ]]; then
  for candidate in "$ROOT_DIR"/actions/*/action.json; do
    [[ -f "$candidate" ]] || continue
    candidate_id="$(jq -r '.id // empty' "$candidate")"
    if [[ "$candidate_id" == "image_generation" && "$ACTION_ID" =~ ^(template-image-render|template-image\.render|render-.*)$ ]]; then
      ACTION_MANIFEST="$candidate"
      break
    fi
  done
fi

[[ -n "$ACTION_MANIFEST" ]] || { echo "Unknown action: $ACTION_ID" >&2; exit 2; }
ACTION_DIR="$(dirname "$ACTION_MANIFEST")"
MANIFEST_VERSION="$(jq -r '.version // empty' "$ACTION_MANIFEST")"
[[ "$MANIFEST_VERSION" == "$ACTION_VERSION" ]] || {
  echo "Action version mismatch. Job requested '$ACTION_VERSION', installed action is '$MANIFEST_VERSION'." >&2
  exit 2
}

SELECTOR="$(jq -r '.execution.selector // empty' "$ACTION_MANIFEST")"
DEFAULT_VARIANT="$(jq -r '.execution.defaultVariant // empty' "$ACTION_MANIFEST")"
VARIANT="$DEFAULT_VARIANT"
if [[ -n "$SELECTOR" ]]; then
  SELECTED_VALUE="$(jq -r --arg selector "$SELECTOR" 'getpath($selector | split(".")) // empty' "$JOB_FILE")"
  if [[ -n "$SELECTED_VALUE" && "$SELECTED_VALUE" != "null" ]]; then
    VARIANT="$SELECTED_VALUE"
  fi
fi

[[ -n "$VARIANT" ]] || { echo "No execution variant selected for $ACTION_ID." >&2; exit 2; }
ENTRYPOINT_REL="$(jq -r '.execution.entrypoint // empty' "$ACTION_MANIFEST")"
[[ -n "$ENTRYPOINT_REL" && "$ENTRYPOINT_REL" != /* && "$ENTRYPOINT_REL" != *".."* ]] || { echo "Unsafe or missing action entrypoint in manifest." >&2; exit 2; }
ENTRYPOINT_FILE="$(realpath "$ACTION_DIR/$ENTRYPOINT_REL")"
case "$ENTRYPOINT_FILE" in
  "$ACTION_DIR"/*) ;;
  *) echo "Action entrypoint resolves outside the action directory." >&2; exit 2 ;;
esac
[[ -f "$ENTRYPOINT_FILE" ]] || { echo "Action entrypoint not found: $ENTRYPOINT_FILE" >&2; exit 2; }
DOCKERFILE_REL="$(jq -r --arg variant "$VARIANT" '.execution.variants[$variant].dockerfile // empty' "$ACTION_MANIFEST")"
[[ -n "$DOCKERFILE_REL" ]] || { echo "Unsupported execution variant '$VARIANT' for $ACTION_ID." >&2; exit 2; }
[[ "$DOCKERFILE_REL" != /* && "$DOCKERFILE_REL" != *".."* ]] || { echo "Unsafe Dockerfile path in action manifest." >&2; exit 2; }
DOCKERFILE="$(realpath "$ACTION_DIR/$DOCKERFILE_REL")"
case "$DOCKERFILE" in
  "$ACTION_DIR"/*) ;;
  *) echo "Dockerfile resolves outside the action directory." >&2; exit 2 ;;
esac
[[ -f "$DOCKERFILE" ]] || { echo "Action Dockerfile not found: $DOCKERFILE" >&2; exit 2; }

MEMORY="$(jq -r --arg variant "$VARIANT" '.execution.variants[$variant].resources.memory // "1g"' "$ACTION_MANIFEST")"
CPUS="$(jq -r --arg variant "$VARIANT" '.execution.variants[$variant].resources.cpus // 1' "$ACTION_MANIFEST")"
NETWORK="$(jq -r --arg variant "$VARIANT" '.execution.variants[$variant].resources.network // false' "$ACTION_MANIFEST")"
SHM_SIZE="$(jq -r --arg variant "$VARIANT" '.execution.variants[$variant].resources.shmSize // "64m"' "$ACTION_MANIFEST")"
[[ "$MEMORY" =~ ^[1-9][0-9]*[kKmMgG]?$ ]] || { echo "Invalid memory setting in action manifest." >&2; exit 2; }
[[ "$CPUS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid CPU setting in action manifest." >&2; exit 2; }
[[ "$SHM_SIZE" =~ ^[1-9][0-9]*[kKmMgG]?$ ]] || { echo "Invalid shared memory setting in action manifest." >&2; exit 2; }

SAFE_ACTION="$(printf '%s' "$ACTION_ID" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g')"
SAFE_VERSION="$(printf '%s' "$ACTION_VERSION" | sed 's/[^a-zA-Z0-9_.-]/-/g')"
ACTION_FINGERPRINT="$(find "$ACTION_DIR" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print substr($1, 1, 12)}')"
IMAGE_TAG="futcheck-${SAFE_ACTION}:${SAFE_VERSION}-${VARIANT}-${ACTION_FINGERPRINT}"

printf 'Action:   %s\nVersion:  %s\nVariant:  %s\nJob:      %s\nImage:    %s\n' \
  "$ACTION_ID" "$ACTION_VERSION" "$VARIANT" "$JOB_ID" "$IMAGE_TAG"

if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  echo "Using cached action image."
else
  echo "Building action image."
  DOCKER_BUILDKIT=1 docker build \
    --file "$DOCKERFILE" \
    --tag "$IMAGE_TAG" \
    "$ACTION_DIR"
fi

DOCKER_ARGS=(
  run --rm --init
  --memory "$MEMORY"
  --cpus "$CPUS"
  --shm-size "$SHM_SIZE"
  --tmpfs /tmp:rw,nosuid,nodev,size=256m
  --mount "type=bind,src=$JOB_FILE,dst=/work/job.json,readonly"
  --mount "type=bind,src=$INPUT_DIR,dst=/work/input,readonly"
  --mount "type=bind,src=$OUTPUT_DIR,dst=/work/output"
)
if [[ "$NETWORK" == "false" ]]; then
  DOCKER_ARGS+=(--network none)
else
  DOCKER_ARGS+=(--network bridge)
fi

set +e
docker "${DOCKER_ARGS[@]}" --entrypoint "/action/${ENTRYPOINT_REL}" "$IMAGE_TAG"
EXECUTION_STATUS=$?
set -e

if [[ ! -f "$OUTPUT_DIR/manifest.json" ]]; then
  echo "Action did not produce /work/output/manifest.json." >&2
  exit 3
fi

if [[ "$EXECUTION_STATUS" -ne 0 ]]; then
  echo "Action container exited with status $EXECUTION_STATUS." >&2
  exit "$EXECUTION_STATUS"
fi

jq -e '.status == "completed"' "$OUTPUT_DIR/manifest.json" >/dev/null || {
  echo "Action exited successfully but manifest status is not completed." >&2
  exit 3
}

echo "Job completed. Manifest: $OUTPUT_DIR/manifest.json"
