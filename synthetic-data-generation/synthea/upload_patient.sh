#!/usr/bin/env bash
set -euo pipefail

# ----- config -----
BASE="${BASE:-http://localhost:8080/fhir}"     # set to your HAPI endpoint
DATA_DIR="${DATA_DIR:-./output/fhir}"
PARALLEL="${PARALLEL:-2}"
# ------------------

post_json () {
  local file="$1"
  echo "→ POST $file"
  local code
  code=$(curl -sS -w "%{http_code}" -o /tmp/resp.$$ \
    -H "Content-Type: application/fhir+json" \
    --data-binary @"$file" "$BASE")
  if [[ "$code" -ge 200 && "$code" -lt 300 ]]; then
    echo "✓ $file ($code)"
  else
    echo "✗ $file ($code)"
    cat /tmp/resp.$$; echo
  fi
  rm -f /tmp/resp.$$
}

echo "Step 1/2: load directory resources (practitioners, hospitals, payers) in order…"
shopt -s nullglob
for f in "$DATA_DIR"/*[Pp]ractitioner*".json" \
         "$DATA_DIR"/*[Hh]ospital*".json" \
         "$DATA_DIR"/*[Pp]ayer*".json"; do
  post_json "$f"
done

echo "Step 2/2: load patient bundles in parallel…"
# exclude the directory files so we don't repost them
find "$DATA_DIR" -maxdepth 1 -type f -name '*.json' \
  ! -iname '*practitioner*' ! -iname '*hospital*' ! -iname '*payer*' -print0 |
xargs -0 -P "$PARALLEL" -I{} bash -c '
  file="$1"
  code=$(curl -sS -w "%{http_code}" -o /tmp/resp.$$ \
    -H "Content-Type: application/fhir+json" \
    --data-binary @"$file" "'"$BASE"'")
  if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
    echo "✓ $file ($code)"
  else
    echo "✗ $file ($code)"; cat /tmp/resp.$$; echo
  fi
  rm -f /tmp/resp.$$
' _ {}
