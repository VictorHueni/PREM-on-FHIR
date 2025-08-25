#!/usr/bin/env bash
set -euo pipefail

# -------- config --------
FHIR_BASE="${FHIR_BASE:-http://localhost:8080/fhir}"
PATTERN="${PATTERN:-${1:-./output/*_batch_bundle_*.json}}"
CURL_RETRIES="${CURL_RETRIES:-3}"
CURL_MAX_TIME="${CURL_MAX_TIME:-600}"   # seconds
USE_ACCEPT="${USE_ACCEPT:-1}"           # 1 = send Accept header
USE_PREFER_MINIMAL="${USE_PREFER_MINIMAL:-1}"
DEBUG="${DEBUG:-0}"                     # 1 = verbose curl
LOG_DIR="${LOG_DIR:-./curl-logs}"       # where to store per-request logs
# ------------------------

shopt -s nullglob

post_json() {
  local file="$1"
  echo "→ POST $file"

  local resp logdir base hdrs err meta trace
  resp="$(mktemp)"
  base="${file##*/}"
  logdir="$LOG_DIR"
  mkdir -p "$logdir"
  hdrs="$logdir/$base.headers.txt"
  err="$logdir/$base.stderr.txt"
  meta="$logdir/$base.meta.json"
  trace="$logdir/$base.trace.txt"

  # Build optional headers array safely
  local header_args=()
  [[ "${USE_ACCEPT:-1}" == "1" ]] && header_args+=(-H "Accept: application/fhir+json")
  [[ "${USE_PREFER_MINIMAL:-1}" == "1" ]] && header_args+=(-H "Prefer: return=minimal")

  # Rich -w JSON for timing visibility
  local wf='{"http_code":%{http_code},"exit_code":0,"time_starttransfer":%{time_starttransfer},"time_total":%{time_total},"size_upload":%{size_upload},"size_download":%{size_download},"speed_upload":%{speed_upload},"speed_download":%{speed_download},"remote_ip":"%{remote_ip}","remote_port":%{remote_port}}'

  # Use -v only if DEBUG=1
  local verb=()
  [[ "${DEBUG:-0}" == "1" ]] && verb=(-v)

  # Do the request
  local http exitc
  local out_json
  out_json=$(
    curl "${verb[@]}" \
      --retry "${CURL_RETRIES:-3}" --retry-all-errors \
      --connect-timeout 5 \
      -m "${CURL_MAX_TIME:-120}" \
      --fail-with-body \
      --dump-header "$hdrs" \
      --trace-ascii "$trace" --trace-time \
      -w "$wf" -o "$resp" \
      -X POST "$FHIR_BASE" \
      -H "Content-Type: application/fhir+json" \
      -H "Expect:" \
      "${header_args[@]}" \
      --data-binary @"$file" \
      2>"$err"
  ) || true
  exitc=$?  # curl’s exit code

  # Patch exit code into the JSON line
  if [[ -n "${out_json:-}" ]]; then
    if command -v jq >/dev/null 2>&1; then
      printf '%s\n' "$out_json" | jq --argjson ec "$exitc" '.exit_code=$ec' >"$meta" || echo "$out_json" >"$meta"
    else
      echo "$out_json" >"$meta"
    fi
  else
    echo "{\"http_code\":0,\"exit_code\":$exitc}" >"$meta"
  fi

  # Read http status if present
  if command -v jq >/dev/null 2>&1; then
    http=$(jq -r '(.http_code//0|tonumber)' <"$meta" 2>/dev/null || echo 0)
  else
    # crude parse: look for "http_code":<n>
    http=$(grep -o '"http_code":[0-9]\+' "$meta" | head -n1 | cut -d: -f2 || echo 0)
  fi
  http="${http:-0}"

  if (( exitc == 0 )) && (( http >= 200 && http < 300 )); then
    echo "✓ SUCCESS ($http)"
    rm -f "$resp" "$hdrs" "$err" "$trace" "$meta"
    return 0
  fi

  # Error path
  if (( exitc == 28 )); then
    echo "✗ TIMEOUT after ${CURL_MAX_TIME:-120}s while posting $file (curl exit 28)."
    echo "  Tip: raise CURL_MAX_TIME, split bundle smaller, or keep Expect disabled."
  else
    echo "✗ ERROR while posting $file (curl exit=$exitc, http=$http)"
  fi
  echo "  Logs:"
  echo "    Headers : $hdrs"
  echo "    Stderr  : $err"
  echo "    Trace   : $trace"
  echo "    Metrics : $meta"

  # Try to render OperationOutcome/body if we got one
  if command -v jq >/dev/null 2>&1; then
    echo "— Server said —"
    jq -r '
      if .resourceType=="OperationOutcome"
      then .issue[]? | "* " + (.severity//"?") + " " + (.code//"?") + ": " + (.diagnostics//(.details.text//""))
      else empty
      end
    ' "$resp" 2>/dev/null || head -n 60 "$resp"
  else
    head -n 60 "$resp"
  fi
  echo "------"
  # Keep resp + logs for inspection
  return 1
}

# ---------- main ----------
files=( $PATTERN )
if (( ${#files[@]} == 0 )); then
  echo "No files matched pattern: $PATTERN"
  exit 0
fi

echo "Target FHIR base: $FHIR_BASE"
echo "Found ${#files[@]} bundle file(s)."

# Optional pre-validation (uncomment to use)
# for f in "${files[@]}"; do
#   echo "→ VALIDATE $f"
#   curl -sS -X POST "$FHIR_BASE/Bundle/\$validate" \
#     -H 'Content-Type: application/fhir+json' \
#     -H 'Accept: application/fhir+json' \
#     --data-binary @"$f" | jq -r '.issue[]? | "* " + (.severity//"?") + " " + (.code//"?") + ": " + (.diagnostics//(.details.text//""))'
# done

for f in "${files[@]}"; do
  post_json "$f"
done

echo "All done."
