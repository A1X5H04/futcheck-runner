#!/usr/bin/env bash
set -Eeuo pipefail

JOB_FILE="/work/job.json"
OUTPUT_DIR="/work/output"

TEMPLATE_ID="$(jq -er '.payload.template | strings' "$JOB_FILE")"
TITLE="$(jq -er '.payload.data.title | strings' "$JOB_FILE")"
SUBTITLE="$(jq -er '.payload.data.subtitle | strings' "$JOB_FILE")"
EYEBROW="$(jq -r '.payload.data.eyebrow // "FUTCHECK"' "$JOB_FILE")"
ACCENT="$(jq -r '.payload.data.accentColor // "#B6F23A"' "$JOB_FILE")"
WIDTH="$(jq -er '.payload.output.width | numbers' "$JOB_FILE")"
HEIGHT="$(jq -er '.payload.output.height | numbers' "$JOB_FILE")"
FORMAT="$(jq -er '.payload.output.format | strings' "$JOB_FILE")"
OUTPUT_PATH="$(jq -r '.payload.output.path // "post.png"' "$JOB_FILE")"

[[ "$TEMPLATE_ID" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { echo "Invalid template identifier." >&2; exit 2; }
[[ "$ACCENT" =~ ^#[0-9A-Fa-f]{6}$ ]] || { echo "accentColor must be a six-digit hex color." >&2; exit 2; }
[[ "$WIDTH" -ge 64 && "$WIDTH" -le 4096 ]] || { echo "Width must be between 64 and 4096." >&2; exit 2; }
[[ "$HEIGHT" -ge 64 && "$HEIGHT" -le 4096 ]] || { echo "Height must be between 64 and 4096." >&2; exit 2; }
[[ "$FORMAT" == "png" ]] || { echo "SVG renderer currently supports PNG output only." >&2; exit 2; }
[[ "$OUTPUT_PATH" != /* && "$OUTPUT_PATH" =~ ^[A-Za-z0-9._/-]+\.png$ ]] || { echo "Invalid output path." >&2; exit 2; }
case "/${OUTPUT_PATH}/" in *"/../"*|*"/./"*) echo "Output path traversal is not allowed." >&2; exit 2 ;; esac

TEMPLATE_FILE="/action/templates/${TEMPLATE_ID}/template.svg"
[[ -f "$TEMPLATE_FILE" ]] || { echo "Unknown SVG template: $TEMPLATE_ID" >&2; exit 2; }

OUTPUT_FILE="${OUTPUT_DIR}/${OUTPUT_PATH}"
mkdir -p "$(dirname "$OUTPUT_FILE")"
RENDERED_SVG="/tmp/rendered-${TEMPLATE_ID}.svg"

jq -nr \
  --rawfile svg "$TEMPLATE_FILE" \
  --arg title "$TITLE" \
  --arg subtitle "$SUBTITLE" \
  --arg eyebrow "$EYEBROW" \
  --arg accent "$ACCENT" \
  '
    def xml_escape:
      gsub("&"; "&amp;")
      | gsub("<"; "&lt;")
      | gsub(">"; "&gt;")
      | gsub("\\\""; "&quot;")
      | gsub("\u0027"; "&apos;");
    $svg
    | split("{{TITLE}}") | join($title | xml_escape)
    | split("{{SUBTITLE}}") | join($subtitle | xml_escape)
    | split("{{EYEBROW}}") | join($eyebrow | xml_escape)
    | split("{{ACCENT}}") | join($accent | xml_escape)
  ' > "$RENDERED_SVG"

resvg \
  --width "$WIDTH" \
  --height "$HEIGHT" \
  --use-fonts-dir /usr/share/fonts/truetype/dejavu \
  --use-fonts-dir /action/assets/fonts \
  --resources-dir "/action/templates/${TEMPLATE_ID}" \
  "$RENDERED_SVG" \
  "$OUTPUT_FILE"

[[ -s "$OUTPUT_FILE" ]] || { echo "resvg did not produce an output image." >&2; exit 3; }
