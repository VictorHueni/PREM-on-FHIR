#!/usr/bin/env bash
set -euo pipefail

# You can override these via env vars:
FHIR_BASE="${FHIR_BASE:-http://localhost:8080/fhir}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"   # seconds

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <parameters.json> [poll-interval-seconds]"
  echo "       FHIR_BASE (env) defaults to ${FHIR_BASE}"
  exit 1
fi

PARAMS_FILE="$1"
if [[ $# -ge 2 ]]; then POLL_INTERVAL="$2"; fi

[[ -f "$PARAMS_FILE" ]] || { echo "❌ Missing file: $PARAMS_FILE"; exit 1; }

extract_job_id() {
  # 1) From Content-Location header
  echo "$1" | grep -i '^Content-Location:' | grep -oE '_jobId=[0-9a-f-]+' | cut -d= -f2 && return 0 || true
  # 2) From body phrase: 'ID: <uuid>'
  echo "$1" | grep -oE 'ID: [0-9a-f-]+' | awk '{print $2}' && return 0 || true
  # 3) From JSON field: "jobId":"<uuid>"
  echo "$1" | grep -oP '"jobId"\s*:\s*"\K[0-9a-f-]+' && return 0 || true
  return 1
}

submit_import() {
  local params_file="$1"
  echo "➡️  Submitting bulk import with ${params_file} ..."
  # Capture headers + body
  local resp
  resp=$(curl -s -i -X POST \
    -H "Content-Type: application/fhir+json" \
    -H "Prefer: respond-async" \
    -d @"${params_file}" \
    "${FHIR_BASE}/\$import")

  echo "Response:"
  echo "$resp"

  local job_id
  if ! job_id=$(extract_job_id "$resp"); then
    echo "❌ Could not extract jobId from response."
    exit 1
  fi
  echo "✅ Job started: ${job_id}"
  printf "%s" "${job_id}"
}

poll_job() {
  local job_id="$1"
  local poll_url="${FHIR_BASE}/\$import-poll-status?_jobId=${job_id}"
  echo "⏳ Polling every ${POLL_INTERVAL}s at:"
  echo "   ${poll_url}"

  while true; do
    # Grab HTTP code + body
    local tmp http body
    tmp="$(mktemp 2>/dev/null || echo "/tmp/bulk_import.$$")"
    http=$(curl -s -o "${tmp}" -w "%{http_code}" "${poll_url}")
    body="$(cat "${tmp}")"
    rm -f "${tmp}"

    echo "---- $(date) ----  [HTTP ${http}]"
    echo "${body}"

    # 202 = still running; 200 = finished (report or status)
    if [[ "${http}" == "202" ]]; then
      sleep "${POLL_INTERVAL}"
      continue
    elif [[ "${http}" == "200" ]]; then
      # Consider failure if body indicates FAILED
      if echo "${body}" | grep -qi '"status"\s*:\s*"FAILED"'; then
        echo "❌ Import FAILED (status)."
        exit 1
      fi
      if echo "${body}" | grep -qi 'Job is in FAILED state'; then
        echo "❌ Import FAILED (OperationOutcome)."
        exit 1
      fi
      echo "✅ Import completed."
      break
    else
      echo "❌ Unexpected response (HTTP ${http})."
      exit 1
    fi
  done
}

main() {
  local job_id
  job_id="$(submit_import "${PARAMS_FILE}")"
  echo
  poll_job "${job_id}"
}

main
