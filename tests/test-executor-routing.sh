#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/input" "$TEMP_DIR/output-svg" "$TEMP_DIR/output-playwright"

cat > "$TEMP_DIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$FUTCHECK_FAKE_DOCKER_LOG"
if [[ "$1" == "image" && "${2:-}" == "inspect" ]]; then
  exit 1
fi
if [[ "$1" == "run" ]]; then
  output_dir=""
  job_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mount)
        mount_spec="$2"
        if [[ "$mount_spec" == *"dst=/work/output"* ]]; then
          output_dir="${mount_spec#*src=}"
          output_dir="${output_dir%%,dst=*}"
        fi
        if [[ "$mount_spec" == *"dst=/work/job.json"* ]]; then
          job_file="${mount_spec#*src=}"
          job_file="${job_file%%,dst=*}"
        fi
        shift 2
        ;;
      *) shift ;;
    esac
  done
  [[ -n "$output_dir" && -n "$job_file" ]]
  printf 'test' > "$output_dir/post.png"
  jq -n \
    --arg jobId "$(jq -r '.jobId' "$job_file")" \
    --arg action "$(jq -r '.action' "$job_file")" \
    --arg version "$(jq -r '.actionVersion' "$job_file")" \
    '{schemaVersion:1,jobId:$jobId,action:$action,actionVersion:$version,status:"completed",output:{files:[{path:"post.png",format:"txt",bytes:4,sha256:"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"}]},execution:{startedAt:"2026-01-01T00:00:00Z",completedAt:"2026-01-01T00:00:01Z",durationMs:1000}}' \
    > "$output_dir/manifest.json"
fi
DOCKER
chmod +x "$TEMP_DIR/bin/docker"

export FUTCHECK_FAKE_DOCKER_LOG="$TEMP_DIR/docker.log"
export PATH="$TEMP_DIR/bin:$PATH"

"$ROOT_DIR/runner/execute.sh" \
  --job "$ROOT_DIR/examples/jobs/render-svg.json" \
  --input "$TEMP_DIR/input" \
  --output "$TEMP_DIR/output-svg"

grep -F -- "Dockerfile.svg" "$FUTCHECK_FAKE_DOCKER_LOG" >/dev/null

"$ROOT_DIR/runner/execute.sh" \
  --preflight \
  --job "$ROOT_DIR/examples/jobs/render-svg.json" \
  --input "$TEMP_DIR/input" \
  --output "$TEMP_DIR/output-svg"

grep -F -- "--preflight" "$FUTCHECK_FAKE_DOCKER_LOG" >/dev/null

"$ROOT_DIR/runner/execute.sh" \
  --job "$ROOT_DIR/examples/jobs/render-playwright.json" \
  --input "$TEMP_DIR/input" \
  --output "$TEMP_DIR/output-playwright"

grep -F -- "Dockerfile.playwright" "$FUTCHECK_FAKE_DOCKER_LOG" >/dev/null

echo "Executor routing tests passed (Docker calls were mocked)."
