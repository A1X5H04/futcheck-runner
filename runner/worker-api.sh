#!/usr/bin/env bash

# Source this file inside a worker that needs to send a meaningful message:
#   source /runner/runner-api.sh
#   runner.send "Downloaded source data" WORKER_MESSAGE

runner_json_escape() {
  LC_ALL=C tr -d '\000-\010\013\014\016-\037' |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e $'s/\t/\\t/g' -e $'s/\r/\\r/g' |
    awk 'BEGIN { ORS="" } { if (NR > 1) printf "\\n"; printf "%s", $0 }'
}

runner.send() {
  local message="${1:?runner.send requires a message}" code="${2:-WORKER_MESSAGE}"
  : "${RUNNER_MESSAGE_FILE:?RUNNER_MESSAGE_FILE is not configured}"
  [[ "$code" =~ ^[A-Z][A-Z0-9_]*$ ]] || { echo "runner.send code must be uppercase snake case." >&2; return 2; }
  [[ ${#message} -le 4000 ]] || { echo "runner.send message exceeds 4000 characters." >&2; return 2; }
  mkdir -p "$(dirname "$RUNNER_MESSAGE_FILE")"
  printf '{"code":"%s","message":"%s"}\n' \
    "$(printf '%s' "$code" | runner_json_escape)" \
    "$(printf '%s' "$message" | runner_json_escape)" >> "$RUNNER_MESSAGE_FILE"
}
