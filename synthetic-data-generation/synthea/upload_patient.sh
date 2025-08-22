#!/usr/bin/env bash
set -euo pipefail

# -------- config --------
FHIR_BASE="${FHIR_BASE:-http://localhost:8080/fhir}"   # unified name
DATA_DIR="${DATA_DIR:-./output/fhir}"
PARALLEL="${PARALLEL:-2}"
CURL_RETRIES="${CURL_RETRIES:-3}"
CURL_MAX_TIME="${CURL_MAX_TIME:-120}"
USE_ACCEPT="${USE_ACCEPT:-1}"
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
    echo "✓ $file ($code)"
  else
    echo "✗ $file ($code)"
    if command -v jq >/dev/null 2>&1; then
      jq -r '
        if .resourceType=="OperationOutcome"
        then .issue[]? | "* " + (.severity//"?") + " " + (.code//"?") + ": " + (.diagnostics//(.details.text//""))
        else .type as $t | .total as $tot | "Bundle response: \($t)// total=\($tot)"
        end
      ' "$resp" 2>/dev/null || head -n 40 "$resp"
    else
      cat "$resp"; echo
    fi
  fi
  rm -f "$resp"
}

echo "Target FHIR base: $FHIR_BASE"
echo "Step 1/2: load directory resources (practitioners, hospitals, payers) in order…"

for f in "$DATA_DIR"/*[Pp]ractitioner*.json \
         "$DATA_DIR"/*[Hh]ospital*.json \
         "$DATA_DIR"/*[Pp]ayer*.json; do
  [[ -e "$f" ]] || continue
  post_json "$f"
done

echo "Step 2/2: load patient bundles in parallel…"
# Exclude the directory files so we don't repost them
mapfile -d '' rest < <(
  find "$DATA_DIR" -maxdepth 1 -type f -name '*.json' \
    ! -iname '*practitioner*' ! -iname '*hospital*' ! -iname '*payer*' -print0
)

if (( ${#rest[@]} == 0 )); then
  echo "No remaining files to load."
  exit 0
fi

# Parallel fan-out
printf '%s\0' "${rest[@]}" | xargs -0 -P "$PARALLEL" -n 1 bash -c '
  file="$0"
  # Inline the same post function behavior for each worker to keep environment simple
  resp="$(mktemp)"
  code=$(
    curl -sS --retry "'"$CURL_RETRIES"'" --retry-all-errors -m "'"$CURL_MAX_TIME"'" -w "%{http_code}" -o "$resp" \
      -X POST "'"$FHIR_BASE"'" -H "Content-Type: application/fhir+json" '"$(
        [[ "$USE_ACCEPT" == "1" ]] && echo "-H 'Accept: application/fhir+json'" || echo
      )"' '"$(
        [[ "$USE_PREFER_MINIMAL" == "1" ]] && echo "-H 'Prefer: return=minimal'" || echo
      )"' --data-binary @"$file"
  ) || code=000
  if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
    echo "✓ $file ($code)"
  else
    echo "✗ $file ($code)"
    if command -v jq >/dev/null 2>&1; then
      jq -r "
        if .resourceType==\"OperationOutcome\"
        then .issue[]? | \"* \" + (.severity//\"?\") + \" \" + (.code//\"?\") + \": \" + (.diagnostics//(.details.text//\"\")) 
        else .type as \$t | .total as \$tot | \"Bundle response: \(\$t)// total=\(\$tot)\"
        end
      " "$resp" 2>/dev/null || head -n 40 "$resp"
    else
      cat "$resp"; echo
    fi
  fi
  rm -f "$resp"
'

echo "All done."
