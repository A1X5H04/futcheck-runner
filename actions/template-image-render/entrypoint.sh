#!/usr/bin/env bash
set -Eeuo pipefail

ACTION_ID="template-image-render"
ACTION_VERSION="1.0.0"
JOB_FILE="/work/job.json"
OUTPUT_DIR="/work/output"
STARTED_EPOCH_MS="$(date +%s%3N)"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
JOB_ID="unknown"

mkdir -p "$OUTPUT_DIR"

write_failure_manifest() {
  local exit_code="$1"
  local message="$2"
  local completed_at duration_ms temp_file
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  duration_ms=$(( $(date +%s%3N) - STARTED_EPOCH_MS ))
  temp_file="${OUTPUT_DIR}/.manifest.json.tmp"
  jq -n \
    --arg jobId "$JOB_ID" \
    --arg action "$ACTION_ID" \
    --arg actionVersion "$ACTION_VERSION" \
    --arg startedAt "$STARTED_AT" \
    --arg completedAt "$completed_at" \
    --arg message "$message" \
    --argjson durationMs "$duration_ms" \
    --argjson exitCode "$exit_code" \
    '{schemaVersion:1,jobId:$jobId,action:$action,actionVersion:$actionVersion,status:"failed",output:{files:[]},execution:{startedAt:$startedAt,completedAt:$completedAt,durationMs:$durationMs},error:{code:"ACTION_EXECUTION_FAILED",message:$message,exitCode:$exitCode}}' \
    > "$temp_file" 2>/dev/null || return 0
  mv "$temp_file" "${OUTPUT_DIR}/manifest.json" 2>/dev/null || true
}

on_exit() {
  local exit_code=$?
  trap - EXIT
  if [[ "$exit_code" -ne 0 ]]; then
    write_failure_manifest "$exit_code" "Action execution failed. Check the action logs for details."
  fi
  exit "$exit_code"
}
trap on_exit EXIT

[[ -f "$JOB_FILE" ]] || { echo "Missing job file: $JOB_FILE" >&2; exit 2; }

jq -e 'type == "object" and .schemaVersion == 1 and (.jobId | type == "string") and (.action | type == "string") and (.actionVersion | type == "string") and (.payload | type == "object")' "$JOB_FILE" >/dev/null
JOB_ID="$(jq -r '.jobId' "$JOB_FILE")"
JOB_ACTION="$(jq -r '.action' "$JOB_FILE")"
JOB_VERSION="$(jq -r '.actionVersion' "$JOB_FILE")"
RENDERER="$(jq -r '.payload.renderer // "svg"' "$JOB_FILE")"

[[ "$JOB_ACTION" == "$ACTION_ID" ]] || { echo "Unexpected action: $JOB_ACTION" >&2; exit 2; }
[[ "$JOB_VERSION" == "$ACTION_VERSION" ]] || { echo "Unsupported action version: $JOB_VERSION" >&2; exit 2; }
[[ "$RENDERER" == "$ACTION_RENDERER" ]] || { echo "Selected renderer '$RENDERER' does not match this image '$ACTION_RENDERER'." >&2; exit 2; }

jq -e '
  .payload as $p
  | ($p.template | type == "string" and test("^[a-z0-9][a-z0-9-]{0,63}$"))
  and (($p.fitMode // "contain") as $fit | ["contain", "cover", "stretch"] | index($fit) != null)
  and ($p.data | type == "object")
  and ($p.data.title | type == "string" and length >= 1 and length <= 120)
  and ($p.data.subtitle | type == "string" and length <= 240)
  and (($p.data.eyebrow // "FUTCHECK") | type == "string" and length <= 80)
  and (($p.data.accentColor // "#B6F23A") | type == "string" and test("^#[0-9A-Fa-f]{6}$"))
  and ($p.output | type == "object")
  and ($p.output.width | type == "number" and floor == . and . >= 64 and . <= 4096)
  and ($p.output.height | type == "number" and floor == . and . >= 64 and . <= 4096)
  and ($p.output.format == "png")
' "$JOB_FILE" >/dev/null || { echo "Payload validation failed. See payload.schema.json." >&2; exit 2; }

OUTPUT_PATH="$(jq -r '.payload.output.path // "post.png"' "$JOB_FILE")"
[[ "$OUTPUT_PATH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*\.png$ ]] || { echo "Invalid output path." >&2; exit 2; }
IFS='/' read -r -a OUTPUT_PARTS <<< "$OUTPUT_PATH"
for part in "${OUTPUT_PARTS[@]}"; do
  [[ -n "$part" && "$part" != "." && "$part" != ".." ]] || { echo "Output path traversal is not allowed." >&2; exit 2; }
done
OUTPUT_FILE="${OUTPUT_DIR}/${OUTPUT_PATH}"
mkdir -p "$(dirname "$OUTPUT_FILE")"

case "$RENDERER" in
  svg) /action/src/render-svg.sh ;;
  playwright) node /action/src/render-playwright.mjs ;;
  *) echo "Unsupported renderer: $RENDERER" >&2; exit 2 ;;
esac

[[ -s "$OUTPUT_FILE" ]] || { echo "Expected output file was not created: $OUTPUT_PATH" >&2; exit 3; }

EXPECTED_WIDTH="$(jq -r '.payload.output.width' "$JOB_FILE")"
EXPECTED_HEIGHT="$(jq -r '.payload.output.height' "$JOB_FILE")"
python3 - "$OUTPUT_FILE" "$EXPECTED_WIDTH" "$EXPECTED_HEIGHT" <<'PY'
import struct
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected_width, expected_height = map(int, sys.argv[2:4])
with path.open("rb") as image:
    header = image.read(24)
if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
    raise SystemExit("Renderer output is not a valid PNG file.")
width, height = struct.unpack(">II", header[16:24])
if (width, height) != (expected_width, expected_height):
    raise SystemExit(
        f"PNG dimensions are {width}x{height}; expected {expected_width}x{expected_height}."
    )
PY

BYTES="$(stat -c %s "$OUTPUT_FILE")"
SHA256="$(sha256sum "$OUTPUT_FILE" | awk '{print $1}')"
COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DURATION_MS=$(( $(date +%s%3N) - STARTED_EPOCH_MS ))
if [[ "$RENDERER" == "svg" ]]; then
  ENGINE="$(resvg --version)"
else
  ENGINE="playwright@${PLAYWRIGHT_VERSION:-unknown}"
fi

jq -n \
  --arg jobId "$JOB_ID" \
  --arg action "$ACTION_ID" \
  --arg actionVersion "$ACTION_VERSION" \
  --arg startedAt "$STARTED_AT" \
  --arg completedAt "$COMPLETED_AT" \
  --arg renderer "$RENDERER" \
  --arg engine "$ENGINE" \
  --arg path "$OUTPUT_PATH" \
  --arg format "png" \
  --arg sha256 "$SHA256" \
  --argjson bytes "$BYTES" \
  --argjson width "$EXPECTED_WIDTH" \
  --argjson height "$EXPECTED_HEIGHT" \
  --argjson durationMs "$DURATION_MS" \
  '{schemaVersion:1,jobId:$jobId,action:$action,actionVersion:$actionVersion,status:"completed",output:{files:[{path:$path,format:$format,width:$width,height:$height,bytes:$bytes,sha256:$sha256}]},execution:{startedAt:$startedAt,completedAt:$completedAt,durationMs:$durationMs},renderer:{name:$renderer,engine:$engine}}' \
  > "${OUTPUT_DIR}/.manifest.json.tmp"
mv "${OUTPUT_DIR}/.manifest.json.tmp" "${OUTPUT_DIR}/manifest.json"

echo "Completed $ACTION_ID job $JOB_ID using $RENDERER."
