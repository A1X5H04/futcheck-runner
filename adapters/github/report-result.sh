#!/usr/bin/env bash
set -Eeuo pipefail

WORK_DIR="${FUTCHECK_WORK_DIR:-${RUNNER_TEMP:-/tmp}/futcheck-work}"
OUTPUT_DIR="$WORK_DIR/output"
MANIFEST_FILE="$OUTPUT_DIR/manifest.json"
JOB_FILE="$WORK_DIR/job.json"

JOB_TOKEN="${FUTCHECK_JOB_TOKEN:-}"
JOB_API_URL="${FUTCHECK_JOB_API_URL:-}"
CALLBACK_URL="${FUTCHECK_CALLBACK_URL:-}"
EXECUTION_STATUS="${EXECUTION_STATUS:-${1:-0}}"

# 1. Resolve Job Key
JOB_KEY=""
if [[ -f "$WORK_DIR/job_key.txt" ]]; then
  JOB_KEY="$(cat "$WORK_DIR/job_key.txt")"
fi
if [[ -z "$JOB_KEY" ]]; then
  JOB_KEY="${FUTCHECK_JOB_KEY:-${FUTCHECK_JOB_ID:-}}"
fi
if [[ -z "$JOB_KEY" && -f "$JOB_FILE" ]]; then
  JOB_KEY="$(jq -r '.jobId // .job_key // .id // empty' "$JOB_FILE")"
fi

echo "=========================================================="
echo "Futcheck Runner: Reporting execution result"
echo "Job Key:          ${JOB_KEY:-<unknown>}"
echo "Execution Status: $EXECUTION_STATUS"
echo "=========================================================="

# 2. Resolve Callback Webhook URL
if [[ -z "$CALLBACK_URL" && -n "$JOB_API_URL" ]]; then
  if [[ "$JOB_API_URL" =~ /jobs/?$ ]] || [[ "$JOB_API_URL" =~ /jobs/ ]]; then
    CALLBACK_URL="${JOB_API_URL%/jobs*}/webhook/callback"
  else
    CALLBACK_URL="${JOB_API_URL%/}/api/workflow/runner/webhook/callback"
  fi
fi

# 3. Check Manifest and Upload Artifact to tmpfiles.org
IS_SUCCESS=false
DOWNLOAD_URL=""
RAW_TMPFILES_URL=""
ERROR_MSG=""

if [[ "$EXECUTION_STATUS" == "0" || "$EXECUTION_STATUS" == "success" ]]; then
  if [[ -f "$MANIFEST_FILE" ]]; then
    MANIFEST_STATUS="$(jq -r '.status // empty' "$MANIFEST_FILE")"
    if [[ "$MANIFEST_STATUS" == "completed" ]]; then
      IS_SUCCESS=true
    else
      ERROR_MSG="Action manifest status is '${MANIFEST_STATUS}', expected 'completed'."
    fi
  else
    ERROR_MSG="Manifest file not found at $MANIFEST_FILE."
  fi
else
  ERROR_MSG="Execution step failed with status $EXECUTION_STATUS."
fi

if [[ "$IS_SUCCESS" == "true" ]]; then
  # Locate artifact to upload
  OUTPUT_REL="$(jq -r '.output.files[0].path // empty' "$MANIFEST_FILE")"
  ARTIFACT_PATH=""
  if [[ -n "$OUTPUT_REL" && -f "$OUTPUT_DIR/$OUTPUT_REL" ]]; then
    ARTIFACT_PATH="$OUTPUT_DIR/$OUTPUT_REL"
  elif [[ -f "$OUTPUT_DIR/post.png" ]]; then
    ARTIFACT_PATH="$OUTPUT_DIR/post.png"
  else
    # Find any image in output directory
    ARTIFACT_PATH="$(find "$OUTPUT_DIR" -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.webp" \) | head -n 1 || true)"
  fi

  if [[ -n "$ARTIFACT_PATH" && -f "$ARTIFACT_PATH" ]]; then
    echo "Found artifact to upload: $ARTIFACT_PATH ($(stat -c %s "$ARTIFACT_PATH") bytes)"
    echo "Uploading artifact to tmpfiles.org..."

    UPLOAD_RESPONSE=""
    UPLOAD_EXIT=0
    UPLOAD_RESPONSE="$(curl --silent --show-error \
      --connect-timeout 15 \
      --max-time 120 \
      -F "file=@$ARTIFACT_PATH" \
      https://tmpfiles.org/api/v1/upload)" || UPLOAD_EXIT=$?

    if [[ "$UPLOAD_EXIT" -eq 0 ]]; then
      STATUS="$(echo "$UPLOAD_RESPONSE" | jq -r '.status // empty')"
      if [[ "$STATUS" == "success" ]]; then
        RAW_TMPFILES_URL="$(echo "$UPLOAD_RESPONSE" | jq -r '.data.url // empty')"
        # Convert web view URL (https://tmpfiles.org/XXXX/file.png) to direct downloadable link (https://tmpfiles.org/dl/XXXX/file.png)
        DOWNLOAD_URL="${RAW_TMPFILES_URL/tmpfiles.org\//tmpfiles.org\/dl\/}"
        echo "Upload succeeded!"
        echo "View URL:     $RAW_TMPFILES_URL"
        echo "Download URL: $DOWNLOAD_URL"
      else
        UPLOAD_ERR="$(echo "$UPLOAD_RESPONSE" | jq -r '.message // "Unknown tmpfiles upload error"')"
        echo "tmpfiles.org upload failed: $UPLOAD_ERR" >&2
        IS_SUCCESS=false
        ERROR_MSG="tmpfiles.org upload failed: $UPLOAD_ERR"
      fi
    else
      echo "Failed to connect to tmpfiles.org (curl exit code $UPLOAD_EXIT)" >&2
      IS_SUCCESS=false
      ERROR_MSG="tmpfiles.org upload connection error"
    fi
  else
    echo "No output artifact image file found in $OUTPUT_DIR" >&2
    IS_SUCCESS=false
    ERROR_MSG="No output image produced."
  fi
fi

# 4. Construct Webhook Callback Payload
CALLBACK_PAYLOAD=""
if [[ "$IS_SUCCESS" == "true" ]]; then
  CALLBACK_PAYLOAD="$(jq -n \
    --arg jobKey "$JOB_KEY" \
    --arg downloadUrl "$DOWNLOAD_URL" \
    --arg rawUrl "$RAW_TMPFILES_URL" \
    --slurpfile manifest "$MANIFEST_FILE" \
    '{
      jobKey: $jobKey,
      status: "SUCCESS",
      resultData: {
        imageUrl: $downloadUrl,
        videoUrl: $downloadUrl,
        downloadUrl: $downloadUrl,
        rawUrl: $rawUrl,
        github_render: {
          imageUrl: $downloadUrl,
          videoUrl: $downloadUrl,
          downloadUrl: $downloadUrl,
          manifest: ($manifest[0] // {})
        }
      }
    }'
  )"
else
  CALLBACK_PAYLOAD="$(jq -n \
    --arg jobKey "$JOB_KEY" \
    --arg errorMsg "$ERROR_MSG" \
    '{
      jobKey: $jobKey,
      status: "FAILED",
      error: $errorMsg,
      retry: false
    }'
  )"
fi

echo "Callback Payload:"
echo "$CALLBACK_PAYLOAD" | jq .

# 5. Send Webhook Callback to Backend if Configured
if [[ -n "$CALLBACK_URL" ]]; then
  echo "Delivering callback to: $CALLBACK_URL"
  CURL_AUTH_HEADER=()
  if [[ -n "$JOB_TOKEN" ]]; then
    CURL_AUTH_HEADER=(-H "Authorization: Bearer $JOB_TOKEN")
  fi

  HTTP_RESP="$(curl --silent --show-error \
    --connect-timeout 10 \
    --max-time 30 \
    -X POST "$CALLBACK_URL" \
    "${CURL_AUTH_HEADER[@]}" \
    -H "Content-Type: application/json" \
    -d "$CALLBACK_PAYLOAD" \
    -w "\n%{http_code}")" || true

  HTTP_CODE="$(echo "$HTTP_RESP" | tail -n 1)"
  HTTP_BODY="$(echo "$HTTP_RESP" | sed '$d')"

  echo "Backend Response [HTTP $HTTP_CODE]: $HTTP_BODY"
  if [[ "$HTTP_CODE" =~ ^2 ]]; then
    echo "Callback successfully received and processed by backend."
  else
    echo "Warning: Callback returned HTTP status $HTTP_CODE." >&2
  fi
else
  echo "No FUTCHECK_CALLBACK_URL or FUTCHECK_JOB_API_URL configured. Skipping webhook callback."
fi

echo "=========================================================="
echo "Futcheck Runner: Result reporting complete"
echo "=========================================================="
