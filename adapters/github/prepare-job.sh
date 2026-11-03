#!/usr/bin/env bash
set -Eeuo pipefail

WORK_DIR="${FUTCHECK_WORK_DIR:-${RUNNER_TEMP:-/tmp}/futcheck-work}"
JOB_FILE="$WORK_DIR/job.json"
INPUT_DIR="$WORK_DIR/input"
OUTPUT_DIR="$WORK_DIR/output"
JOB_JSON="${FUTCHECK_JOB_JSON:-}"
JOB_ID="${FUTCHECK_JOB_ID:-}"
JOB_KEY_INPUT="${FUTCHECK_JOB_KEY:-}"
JOB_API_URL="${FUTCHECK_JOB_API_URL:-}"
JOB_TOKEN="${FUTCHECK_JOB_TOKEN:-}"
ALLOWED_HOSTS="${FUTCHECK_ALLOWED_JOB_HOSTS:-}"
RUNNER_METADATA_JSON="${FUTCHECK_RUNNER_METADATA:-}"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

if [[ -n "$JOB_JSON" && -n "$JOB_ID" ]]; then
  echo "Provide either job_json or job_id, not both." >&2
  exit 2
fi
if [[ -z "$JOB_JSON" && -z "$JOB_ID" ]]; then
  echo "A job_json or job_id workflow input is required." >&2
  exit 2
fi

if [[ -n "$JOB_JSON" ]]; then
  printf '%s' "$JOB_JSON" > "$JOB_FILE"
else
  [[ "$JOB_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || { echo "Invalid job_id." >&2; exit 2; }
  [[ "$JOB_API_URL" =~ ^https?:// ]] || { echo "FUTCHECK_JOB_API_URL must start with http:// or https://." >&2; exit 2; }
  [[ -n "$JOB_TOKEN" ]] || { echo "FUTCHECK_JOB_TOKEN is required when retrieving a job by ID." >&2; exit 2; }

  URL_WITHOUT_SCHEME="${JOB_API_URL#*://}"
  URL_AUTHORITY="${URL_WITHOUT_SCHEME%%/*}"
  URL_HOST="${URL_AUTHORITY%%:*}"

  if [[ -n "$ALLOWED_HOSTS" && "$ALLOWED_HOSTS" != "*" ]]; then
    HOST_ALLOWED=false
    IFS=',' read -r -a HOST_LIST <<< "$ALLOWED_HOSTS"
    for allowed_host in "${HOST_LIST[@]}"; do
      allowed_host="$(printf '%s' "$allowed_host" | tr '[:upper:]' '[:lower:]' | xargs)"
      if [[ "${URL_HOST,,}" == "$allowed_host" ]]; then
        HOST_ALLOWED=true
        break
      fi
    done
    [[ "$HOST_ALLOWED" == true ]] || { echo "Job API host '$URL_HOST' is not in the configured allowlist ($ALLOWED_HOSTS)." >&2; exit 2; }
  fi

  # Determine proper endpoint URL for fetching job from backend
  if [[ "$JOB_API_URL" =~ /jobs/?$ ]] || [[ "$JOB_API_URL" =~ /jobs/ ]]; then
    FETCH_URL="${JOB_API_URL%/}/${JOB_ID}"
  else
    FETCH_URL="${JOB_API_URL%/}/api/workflow/runner/jobs/${JOB_ID}"
  fi

  echo "Fetching job from $FETCH_URL..."
  curl --fail --silent --show-error \
    --connect-timeout 15 \
    --max-time 60 \
    --header "Authorization: Bearer ${JOB_TOKEN}" \
    --output "$JOB_FILE" \
    "$FETCH_URL"
fi

# Normalize and adapt the job file to the Runner job envelope format
python3 - "$JOB_FILE" "$JOB_ID" "$JOB_KEY_INPUT" "$WORK_DIR/job_key.txt" "$WORK_DIR/job_id.txt" "$WORK_DIR/runner_metadata.json" "$RUNNER_METADATA_JSON" <<'PY'
import json
import sys
import uuid
from pathlib import Path

job_file = Path(sys.argv[1])
job_id_param = sys.argv[2] if len(sys.argv) > 2 else ""
job_key_param = sys.argv[3] if len(sys.argv) > 3 else ""
job_key_out = Path(sys.argv[4]) if len(sys.argv) > 4 else None
job_id_out = Path(sys.argv[5])
metadata_out = Path(sys.argv[6])
metadata_input = sys.argv[7] if len(sys.argv) > 7 else ""

raw = json.loads(job_file.read_text(encoding="utf-8"))

# Determine correlation job_key for backend callback
resolved_job_key = (
    job_key_param
    or raw.get("job_key")
    or raw.get("jobKey")
    or raw.get("jobId")
    or raw.get("id")
    or job_id_param
    or "unknown-job"
)
if job_key_out:
    job_key_out.write_text(str(resolved_job_key), encoding="utf-8")

backend_job_id = raw.get("id") or job_id_param
try:
    backend_job_id = str(uuid.UUID(str(backend_job_id)))
except (ValueError, TypeError, AttributeError):
    # Inline jobs are useful for local/manual execution but have no backend row.
    backend_job_id = str(uuid.uuid4())
job_id_out.write_text(str(backend_job_id), encoding="utf-8")

if metadata_input:
    callback_metadata = json.loads(metadata_input)
else:
    current_step = raw.get("current_step")
    step = (raw.get("steps") or {}).get(current_step, {}) if current_step else {}
    runner = step.get("runner", {}) if isinstance(step, dict) else {}
    callback_metadata = {
        "workflowStep": current_step,
        "executionId": runner.get("executionId"),
    }
callback_metadata = {k: v for k, v in callback_metadata.items() if v is not None}
metadata_out.write_text(json.dumps(callback_metadata, separators=(",", ":")), encoding="utf-8")

is_runner_envelope = (
    raw.get("schemaVersion") == 1
    and isinstance(raw.get("jobId"), str)
    and isinstance(raw.get("action"), str)
    and isinstance(raw.get("actionVersion"), str)
    and isinstance(raw.get("payload"), dict)
)

if is_runner_envelope:
    # If legacy action name was used, normalize to image_generation
    if raw["action"] in ("template-image-render", "template-image.render"):
        raw["action"] = "image_generation"
    envelope = raw
else:
    # Adapt from futcheck_backend WorkflowJob format
    payload = raw.get("payload") if isinstance(raw.get("payload"), dict) else {}

    # Action determination: for now, map all image/rendering requests to image_generation
    action = payload.get("action") or payload.get("actionId") or "image_generation"
    if action in ("template-image-render", "template-image.render") or action.startswith("render-"):
        action = "image_generation"

    # Extract template, renderer, and fitting options
    template = payload.get("template") or "feature-announcement"
    renderer = payload.get("renderer") or "svg"
    fit_mode = payload.get("fitMode") or "contain"

    data = payload.get("data") if isinstance(payload.get("data"), dict) else {}
    fut_data = payload.get("futData") if isinstance(payload.get("futData"), dict) else {}
    sbc_data = fut_data.get("sbc") if isinstance(fut_data.get("sbc"), dict) else {}

    # Smart title extraction
    title = (
        data.get("title")
        or sbc_data.get("name")
        or fut_data.get("name")
        or fut_data.get("headline")
        or payload.get("title")
        or payload.get("caption")
        or "FUTCHECK UPDATE"
    )
    title = str(title).strip()[:120]
    if not title:
        title = "FUTCHECK UPDATE"

    # Smart subtitle extraction
    subtitle = (
        data.get("subtitle")
        or payload.get("parsedCaption")
        or payload.get("caption")
        or (f"Rating: {sbc_data.get('rating')}" if sbc_data.get("rating") else "")
        or "Available now in Ultimate Team"
    )
    subtitle = str(subtitle).strip()[:240]

    # Smart eyebrow extraction
    eyebrow = (
        data.get("eyebrow")
        or fut_data.get("eyebrow")
        or payload.get("eyebrow")
        or (sbc_data.get("category") if sbc_data.get("category") else None)
        or "FUTCHECK"
    )
    eyebrow = str(eyebrow).strip()[:80]
    if not eyebrow:
        eyebrow = "FUTCHECK"

    accent = data.get("accentColor") or payload.get("accentColor") or "#B6F23A"
    if not (isinstance(accent, str) and accent.startswith("#") and len(accent) == 7):
        accent = "#B6F23A"

    out = payload.get("output") if isinstance(payload.get("output"), dict) else {}
    width = out.get("width") or 1080
    height = out.get("height") or 1350
    try:
        width = int(width)
    except (ValueError, TypeError):
        width = 1080
    try:
        height = int(height)
    except (ValueError, TypeError):
        height = 1350

    output_obj = {
        "path": out.get("path") or "post.png",
        "width": width,
        "height": height,
        "format": "png",
    }

    runner_payload = {
        "renderer": renderer,
        "template": template,
        "fitMode": fit_mode,
        "data": {
            "title": title,
            "subtitle": subtitle,
            "eyebrow": eyebrow,
            "accentColor": accent,
        },
        "output": output_obj,
    }

    envelope = {
        "schemaVersion": 1,
        "jobId": str(resolved_job_key),
        "action": action,
        "actionVersion": "1.0.0",
        "payload": runner_payload,
        "metadata": {
            "backend_job_id": raw.get("id"),
            "backend_job_key": raw.get("job_key"),
            "worker_name": raw.get("worker_name"),
        },
    }

job_file.write_text(json.dumps(envelope, indent=2) + "\n", encoding="utf-8")
PY

jq -e 'type == "object" and .schemaVersion == 1 and (.jobId | type == "string" and length > 0) and (.action | type == "string" and length > 0) and (.actionVersion | type == "string" and length > 0) and (.payload | type == "object")' "$JOB_FILE" >/dev/null \
  || { echo "The retrieved job does not match the Runner job envelope." >&2; exit 2; }

chmod 0444 "$JOB_FILE"
echo "Prepared job $(jq -r '.jobId' "$JOB_FILE") at $JOB_FILE"
