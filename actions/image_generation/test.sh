#!/usr/bin/env bash
set -Eeuo pipefail

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVG_TEMPLATE="$ACTION_DIR/templates/feature-announcement/template.svg"
HTML_TEMPLATE="$ACTION_DIR/templates/feature-announcement/index.html"
[[ -f "$SVG_TEMPLATE" && -f "$HTML_TEMPLATE" ]]
for token in '{{TITLE}}' '{{SUBTITLE}}' '{{EYEBROW}}' '{{ACCENT}}'; do
  grep -F -- "$token" "$SVG_TEMPLATE" >/dev/null
  grep -F -- "$token" "$HTML_TEMPLATE" >/dev/null
done

if command -v node >/dev/null 2>&1; then
  node --check "$ACTION_DIR/src/render-playwright.mjs"
else
  echo "Node.js is unavailable; skipping image_generation Playwright syntax check."
fi
