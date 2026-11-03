#!/usr/bin/env bash
set -Eeuo pipefail

WORK_DIR="${FUTCHECK_WORK_DIR:-${RUNNER_TEMP:-/tmp}/futcheck-work}"
OUTPUT_DIR="$WORK_DIR/output"
MANIFEST_FILE="$OUTPUT_DIR/manifest.json"
RESULT_FILE="${RUNNER_RESULT_FILE:-$WORK_DIR/job_result.json}"

[[ -f "$MANIFEST_FILE" ]] || { echo "Action result manifest is missing." >&2; exit 3; }
jq -e '.status == "completed"' "$MANIFEST_FILE" >/dev/null || {
  echo "Action result manifest is not completed." >&2
  exit 3
}

output_rel="$(jq -r '.output.files[0].path // empty' "$MANIFEST_FILE")"
artifact=""
if [[ -n "$output_rel" && -f "$OUTPUT_DIR/$output_rel" ]]; then
  artifact="$OUTPUT_DIR/$output_rel"
elif [[ -f "$OUTPUT_DIR/post.png" ]]; then
  artifact="$OUTPUT_DIR/post.png"
else
  artifact="$(find "$OUTPUT_DIR" -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.webp' -o -name '*.mp4' \) | head -n 1 || true)"
fi
[[ -n "$artifact" && -f "$artifact" ]] || { echo "No publishable action artifact was produced." >&2; exit 3; }

upload_response="$(curl --fail --silent --show-error --connect-timeout 15 --max-time 120 \
  -F "file=@$artifact" https://tmpfiles.org/api/v1/upload)"
raw_url="$(printf '%s' "$upload_response" | jq -er 'select(.status == "success") | .data.url')"
download_url="${raw_url/tmpfiles.org\//tmpfiles.org\/dl\/}"

jq -n \
  --arg imageUrl "$download_url" \
  --arg videoUrl "$download_url" \
  --arg downloadUrl "$download_url" \
  --arg rawUrl "$raw_url" \
  --slurpfile manifest "$MANIFEST_FILE" \
  '{
    imageUrl: $imageUrl,
    videoUrl: $videoUrl,
    downloadUrl: $downloadUrl,
    rawUrl: $rawUrl,
    manifest: ($manifest[0] // {})
  }' > "$RESULT_FILE"

echo "Artifact published: $download_url"
