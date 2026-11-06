#!/usr/bin/env bash
set -Eeuo pipefail

OPERATION="${1:?driver operation required}"
: "${RUNNER_ROOT_DIR:?}"
: "${RUNNER_JOB_FILE:?}"
: "${RUNNER_INPUT_DIR:?}"
: "${RUNNER_OUTPUT_DIR:?}"
: "${RUNNER_ACTION_ID:?}"
: "${RUNNER_ACTION_VERSION:?}"
: "${RUNNER_ACTION_MANIFEST:?}"
: "${RUNNER_ACTION_DIR:?}"
: "${RUNNER_ACTION_VARIANT:?}"

manifest_value() {
  jq -r --arg variant "$RUNNER_ACTION_VARIANT" "$1" "$RUNNER_ACTION_MANIFEST"
}

resolve_action_file() {
  local relative="$1" label="$2" resolved
  [[ -n "$relative" && "$relative" != /* && "$relative" != *".."* ]] || { echo "Unsafe $label path." >&2; exit 2; }
  resolved="$(realpath "$RUNNER_ACTION_DIR/$relative")"
  case "$resolved" in "$RUNNER_ACTION_DIR"/*) ;; *) echo "$label escapes the action directory." >&2; exit 2 ;; esac
  [[ -f "$resolved" ]] || { echo "$label is missing: $relative" >&2; exit 2; }
}

ENTRYPOINT_REL="$(jq -r '.execution.entrypoint // empty' "$RUNNER_ACTION_MANIFEST")"
PREFLIGHT_REL="$(jq -r '.execution.preflight // .execution.entrypoint // empty' "$RUNNER_ACTION_MANIFEST")"
DOCKERFILE_REL="$(manifest_value '.execution.variants[$variant].dockerfile // empty')"
resolve_action_file "$ENTRYPOINT_REL" "action entrypoint"
resolve_action_file "$PREFLIGHT_REL" "action preflight"
resolve_action_file "$DOCKERFILE_REL" "action Dockerfile"

MEMORY="$(manifest_value '.execution.variants[$variant].resources.memory // "1g"')"
CPUS="$(manifest_value '.execution.variants[$variant].resources.cpus // 1')"
NETWORK="$(manifest_value '.execution.variants[$variant].resources.network // false')"
SHM_SIZE="$(manifest_value '.execution.variants[$variant].resources.shmSize // "64m"')"
TIMEOUT_SECONDS="$(manifest_value '.execution.variants[$variant].resources.timeoutSeconds // 900')"
[[ "$MEMORY" =~ ^[1-9][0-9]*[kKmMgG]?$ ]] || { echo "Invalid memory limit." >&2; exit 2; }
[[ "$CPUS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid CPU limit." >&2; exit 2; }
[[ "$NETWORK" == "true" || "$NETWORK" == "false" ]] || { echo "Invalid network setting." >&2; exit 2; }
[[ "$SHM_SIZE" =~ ^[1-9][0-9]*[kKmMgG]?$ ]] || { echo "Invalid shared-memory limit." >&2; exit 2; }
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid timeout limit." >&2; exit 2; }

[[ "$OPERATION" == "validate" ]] && exit 0
[[ "$OPERATION" == "preflight" || "$OPERATION" == "execute" ]] || { echo "Unsupported Docker driver operation." >&2; exit 2; }
for command in docker timeout sha256sum; do
  command -v "$command" >/dev/null 2>&1 || { echo "$command is required by the Docker driver." >&2; exit 2; }
done

SAFE_ACTION="$(printf '%s' "$RUNNER_ACTION_ID" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g')"
SAFE_VERSION="$(printf '%s' "$RUNNER_ACTION_VERSION" | sed 's/[^a-zA-Z0-9_.-]/-/g')"
FINGERPRINT="$(find "$RUNNER_ACTION_DIR" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print substr($1,1,12)}')"
IMAGE_TAG="futcheck-${SAFE_ACTION}:${SAFE_VERSION}-${RUNNER_ACTION_VARIANT}-${FINGERPRINT}"

if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  DOCKER_BUILDKIT=1 docker build --file "$RUNNER_ACTION_DIR/$DOCKERFILE_REL" --tag "$IMAGE_TAG" "$RUNNER_ACTION_DIR"
fi

RUN_OUTPUT_DIR="$RUNNER_OUTPUT_DIR"
if [[ "$OPERATION" == "preflight" ]]; then
  RUN_OUTPUT_DIR="$(mktemp -d)"
  trap 'rm -rf "$RUN_OUTPUT_DIR"' EXIT
else
  if find "$RUNNER_OUTPUT_DIR" -mindepth 1 -print -quit | grep -q .; then
    echo "Output directory must be empty before worker execution." >&2
    exit 2
  fi
fi

DOCKER_ARGS=(run --rm --init --memory "$MEMORY" --cpus "$CPUS" --shm-size "$SHM_SIZE"
  --tmpfs /tmp:rw,nosuid,nodev,size=256m
  --mount "type=bind,src=$RUNNER_JOB_FILE,dst=/work/job.json,readonly"
  --mount "type=bind,src=$RUNNER_INPUT_DIR,dst=/work/input,readonly"
  --mount "type=bind,src=$RUN_OUTPUT_DIR,dst=/work/output")
[[ "$NETWORK" == "false" ]] && DOCKER_ARGS+=(--network none) || DOCKER_ARGS+=(--network bridge)

ENTRYPOINT="$ENTRYPOINT_REL"
COMMAND_ARGS=()
if [[ "$OPERATION" == "preflight" ]]; then ENTRYPOINT="$PREFLIGHT_REL"; COMMAND_ARGS+=(--preflight); fi

set +e
timeout --signal=TERM --kill-after=15s "${TIMEOUT_SECONDS}s" \
  docker "${DOCKER_ARGS[@]}" --entrypoint "/action/$ENTRYPOINT" "$IMAGE_TAG" "${COMMAND_ARGS[@]}"
STATUS=$?
set -e
(( STATUS == 0 )) || { echo "Docker driver $OPERATION failed with status $STATUS." >&2; exit "$STATUS"; }
[[ "$OPERATION" == "preflight" ]] && exit 0

