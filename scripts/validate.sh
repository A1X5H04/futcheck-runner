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

bash ./tests/test-executor-routing.sh
bash ./tests/test-supervisor.sh
bash ./tests/test-dispatcher.sh
bash ./tests/test-reporting-flow.sh

for action_test in actions/*/test.sh; do
  [[ -e "$action_test" ]] || continue
  bash "$action_test"
done

echo "Static validation passed. Docker rendering has not been run by this script."
