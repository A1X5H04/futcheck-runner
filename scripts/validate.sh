#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

command -v jq >/dev/null 2>&1 || { echo "jq is required for validation." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required for validation." >&2; exit 2; }

python3 scripts/validate.py

while IFS= read -r -d '' file; do
  bash -n "$file"
done < <(find runner adapters scripts actions tests -type f -name '*.sh' -print0)

./tests/test-executor-routing.sh

if command -v node >/dev/null 2>&1; then
  node --check actions/template-image-render/src/render-playwright.mjs
else
  echo "Node.js is not installed locally; skipping the optional Playwright script syntax check."
fi

echo "Static validation passed. Docker rendering has not been run by this script."
