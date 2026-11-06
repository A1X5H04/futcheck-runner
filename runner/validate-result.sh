#!/usr/bin/env bash
set -Eeuo pipefail

JOB_FILE="${1:?job file required}"
MANIFEST_FILE="${2:?manifest file required}"
OUTPUT_DIR="${3:?output directory required}"
MAX_OUTPUT_BYTES="${4:?output byte limit required}"

JOB_ID="$(jq -r '.jobId' "$JOB_FILE")"
ACTION_ID="$(jq -r '.action' "$JOB_FILE")"
ACTION_VERSION="$(jq -r '.actionVersion' "$JOB_FILE")"

jq -e --arg jobId "$JOB_ID" --arg action "$ACTION_ID" --arg version "$ACTION_VERSION" '
  type == "object"
  and .schemaVersion == 1
  and .jobId == $jobId
  and .action == $action
  and .actionVersion == $version
  and .status == "completed"
  and (.execution | type == "object")
  and (.execution.startedAt | type == "string" and length > 0)
  and (.execution.completedAt | type == "string" and length > 0)
  and (.execution.durationMs | type == "number" and floor == . and . >= 0)
  and (.output | type == "object")
  and (.output.files | type == "array")
  and all(.output.files[];
    (.path | type == "string" and length > 0)
    and (.format | type == "string" and length > 0)
    and (.bytes | type == "number" and floor == . and . >= 0)
    and (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))
  )
' "$MANIFEST_FILE" >/dev/null || { echo "Result manifest does not satisfy the runner contract." >&2; exit 3; }

OUTPUT_BYTES="$(du -sb "$OUTPUT_DIR" | awk '{print $1}')"
(( OUTPUT_BYTES <= MAX_OUTPUT_BYTES )) || { echo "Output exceeds the declared byte limit." >&2; exit 3; }

while IFS=$'\t' read -r relative_path expected_bytes expected_sha; do
  IFS='/' read -r -a parts <<< "$relative_path"
  for part in "${parts[@]}"; do
    [[ -n "$part" && "$part" != "." && "$part" != ".." ]] || { echo "Unsafe output path in result manifest." >&2; exit 3; }
  done
  [[ "$relative_path" != /* ]] || { echo "Absolute output path in result manifest." >&2; exit 3; }
  output_file="$(realpath -m "$OUTPUT_DIR/$relative_path")"
  case "$output_file" in "$OUTPUT_DIR"/*) ;; *) echo "Output path escapes the output directory." >&2; exit 3 ;; esac
  [[ -f "$output_file" ]] || { echo "Declared output is missing: $relative_path" >&2; exit 3; }
  [[ "$(stat -c %s "$output_file")" == "$expected_bytes" ]] || { echo "Output byte count mismatch: $relative_path" >&2; exit 3; }
  [[ "$(sha256sum "$output_file" | awk '{print $1}')" == "$expected_sha" ]] || { echo "Output digest mismatch: $relative_path" >&2; exit 3; }
done < <(jq -r '.output.files[] | [.path, (.bytes | tostring), .sha256] | @tsv' "$MANIFEST_FILE")
