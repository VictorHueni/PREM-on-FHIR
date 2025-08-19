#!/usr/bin/env bash
set -euo pipefail

BASE="http://localhost:8080/fhir"

for f in ./output/nreq_batch_bundle_*.json; do
  echo "→ POST $f"

  # send request, capture response and code
  resp=$(mktemp)
  code=$(curl -sS -w "%{http_code}" -o "$resp" \
    -X POST "$BASE" \
    -H "Content-Type: application/fhir+json" \
    -H "Accept: application/fhir+json" \
    -H "Prefer: return=minimal" \
    --data-binary @"$f") || code=000

  if [[ "$code" -ge 200 && "$code" -lt 300 ]]; then
    echo "✓ SUCCESS ($code)"
  else
    echo "✗ ERROR ($code) while posting $f"
    # show first 20 lines of response for debugging
    head -n 20 "$resp"
    echo "------"
  fi

  rm -f "$resp"
done
