#!/usr/bin/env bash
set -euo pipefail

# -------- config --------
FHIR_BASE="${FHIR_BASE:-http://localhost:8080/fhir}"
PATTERN="${PATTERN:-${1:-./output/*_batch_bundle_*.json}}"
CURL_RETRIES="${CURL_RETRIES:-3}"
CURL_MAX_TIME="${CURL_MAX_TIME:-120}"   # seconds
USE_ACCEPT="${USE_ACCEPT:-1}"           # 1 = send Accept header
USE_PREFER_MINIMAL="${USE_PREFER_MINIMAL:-1}"
# ------------------------

shopt -s nullglob

_header_flags() {
  [[ "$USE_ACCEPT" == "1" ]] && printf -- "-H" "Accept: application/fhir+json " || true
  [[ "$USE_PREFER_MINIMAL" == "1" ]] && printf -- "-H" "Prefer: return=minimal " || true
}

post_json() {
  local file="$1"
  echo "→ POST $file"
  local resp code
  resp="$(mktemp)"
  # shellcheck disable=SC2046
  code=$(
    curl -sS \
      --retry "$CURL_RETRIES" --retry-all-errors \
      -m "$CURL_MAX_TIME" -w "%{http_code}" -o "$resp" \
      -X POST "$FHIR_BASE" \
      -H "Content-Type: application/fhir+json" \
      $( _header_flags ) \
      --data-binary @"$file"
  ) || code=000

  if [[ "$code" -ge 200 && "$code" -lt 300 ]]; then
    echo "✓ SUCCESS ($code)"
  else
    echo "✗ ERROR ($code) while posting $file"
    if command -v jq >/dev/null 2>&1; then
      echo "— Server said —"
      jq -r '
        if .resourceType=="OperationOutcome"
        then .issue[]? | "* " + (.severity//"?") + " " + (.code//"?") + ": " + (.diagnostics//(.details.text//""))
        else .type as $t | .total as $tot | "Bundle response: \($t)// total=\($tot)"
        end
      ' "$resp" 2>/dev/null || head -n 40 "$resp"
    else
      head -n 40 "$resp"
    fi
    echo "------"
  fi
  rm -f "$resp"
}

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
