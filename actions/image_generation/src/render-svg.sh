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
OUTPUT_PATH="$(jq -r '.payload.output.path // "post.png"' "$JOB_FILE")"
FIT_MODE="$(jq -r '.payload.fitMode // "contain"' "$JOB_FILE")"

[[ "$TEMPLATE_ID" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { echo "Invalid template identifier." >&2; exit 2; }
[[ "$ACCENT" =~ ^#[0-9A-Fa-f]{6}$ ]] || { echo "accentColor must be a six-digit hex color." >&2; exit 2; }
[[ "$WIDTH" -ge 64 && "$WIDTH" -le 4096 ]] || { echo "Width must be between 64 and 4096." >&2; exit 2; }
[[ "$HEIGHT" -ge 64 && "$HEIGHT" -le 4096 ]] || { echo "Height must be between 64 and 4096." >&2; exit 2; }
[[ "$FIT_MODE" == "contain" || "$FIT_MODE" == "cover" || "$FIT_MODE" == "stretch" ]] || { echo "Unsupported SVG fitMode: $FIT_MODE" >&2; exit 2; }
[[ "$OUTPUT_PATH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*\.png$ ]] || { echo "Invalid output path." >&2; exit 2; }

TEMPLATE_DIR="/action/templates/${TEMPLATE_ID}"
TEMPLATE_FILE="${TEMPLATE_DIR}/template.svg"
[[ -f "$TEMPLATE_FILE" ]] || { echo "Unknown SVG template: $TEMPLATE_ID" >&2; exit 2; }
OUTPUT_FILE="${OUTPUT_DIR}/${OUTPUT_PATH}"
mkdir -p "$(dirname "$OUTPUT_FILE")"
RENDERED_SVG="/tmp/rendered-${TEMPLATE_ID}.svg"
CANVAS_SVG="/tmp/canvas-${TEMPLATE_ID}.svg"

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

python3 - "$RENDERED_SVG" "$CANVAS_SVG" "$WIDTH" "$HEIGHT" "$FIT_MODE" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

source, destination = map(Path, sys.argv[1:3])
width, height = map(int, sys.argv[3:5])
fit_mode = sys.argv[5]
svg_ns = "http://www.w3.org/2000/svg"
xlink_ns = "http://www.w3.org/1999/xlink"
ET.register_namespace("", svg_ns)
ET.register_namespace("xlink", xlink_ns)

try:
    original = ET.parse(source).getroot()
except ET.ParseError as exc:
    raise SystemExit(f"Invalid SVG template: {exc}")
if original.tag != f"{{{svg_ns}}}svg":
    raise SystemExit("The template root must be an SVG element.")
view_box = original.attrib.get("viewBox") or original.attrib.get("viewbox")
if not view_box:
    raise SystemExit("SVG templates must define a viewBox.")
try:
    values = [float(item) for item in view_box.replace(",", " ").split()]
except ValueError:
    raise SystemExit("SVG viewBox must contain four numeric values.")
if len(values) != 4 or values[2] <= 0 or values[3] <= 0:
    raise SystemExit("SVG viewBox must contain four values with positive width and height.")

preserve = {
    "contain": "xMidYMid meet",
    "cover": "xMidYMid slice",
    "stretch": "none",
}[fit_mode]
outer = ET.Element(f"{{{svg_ns}}}svg", {
    "width": str(width),
    "height": str(height),
    "viewBox": f"0 0 {width} {height}",
})
inner = ET.SubElement(outer, f"{{{svg_ns}}}svg", {
    "x": "0",
    "y": "0",
    "width": str(width),
    "height": str(height),
    "viewBox": view_box,
    "preserveAspectRatio": preserve,
})
for key, value in original.attrib.items():
    if key not in {"width", "height", "viewBox", "viewbox", "preserveAspectRatio", "x", "y"}:
        inner.set(key, value)
if fit_mode == "cover":
    inner.set("overflow", "hidden")
for child in list(original):
    inner.append(child)

ET.ElementTree(outer).write(destination, encoding="utf-8", xml_declaration=True)
PY

resvg \
  --width "$WIDTH" \
  --height "$HEIGHT" \
  --use-fonts-dir /usr/share/fonts/truetype/dejavu \
  --use-fonts-dir /action/assets/fonts \
  --resources-dir "$TEMPLATE_DIR" \
  "$CANVAS_SVG" \
  "$OUTPUT_FILE"

[[ -s "$OUTPUT_FILE" ]] || { echo "resvg did not produce an output image." >&2; exit 3; }
