#!/usr/bin/env python3
"""
make_qr_bundles.py (commented)
--------------------------------
Reads a CSV of QuestionnaireResponse rows and writes chunked FHIR Bundles (type=batch)
into ./output by default.

Design goals / assumptions:
- Input is a flat CSV with one row per intended QuestionnaireResponse.
- We keep the bundle entries lean: only the QuestionnaireResponse resources.
- All references (Patient/Encounter/Practitioner) point to resources that already
  exist on the server → therefore we emit **absolute** references (no in-bundle
  dependency resolution needed).
- Each Bundle.entry gets a fullUrl (urn:uuid:...), which is required by some servers
  when validating bundles that contain relative references; although our refs are absolute,
  adding fullUrl is harmless and future-proofs if you later include contained resources.

Interoperability:
- Answers use textual codes: disagree | neutral | agree (your CodeSystem).
- Any ordinal scoring is conveyed via terminology (CodeSystem concepts), not by
  using numbers as codes in QR — this is the most portable approach.

Operational notes:
- Chunking avoids server-side OOM/GC churn during POST/$validate.
- We normalize authored datetime inputs to FHIR-compatible ISO-8601.
"""

import argparse
import csv
import json
import os
import uuid
from datetime import datetime, timezone

# FHIR base URL: where your HAPI server lives.
# Allow override via env so you can run the same script against dev/test/prod.
FHIR_BASE = os.environ.get("FHIR_BASE", "http://localhost:8080/fhir")


def detect_delimiter(csv_path: str) -> str:
    """
    Heuristically detect CSV delimiter. We try Sniffer first, then fall back to the most
    plausible of [';', ','] based on frequency. This accommodates locales where ';' is default.
    """
    with open(csv_path, 'r', encoding='utf-8-sig', newline='') as f:
        sample = f.read(4096)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=";,|\t,")
            return dialect.delimiter
        except Exception:
            # Fallback: simple frequency vote; prefer ';' if it's as frequent as ','.
            return ';' if sample.count(';') >= sample.count(',') else ','


def get_first_present(row_ci: dict, *names):
    """
    Return the first non-empty value from the row for any of the provided column names.
    - `row_ci` is a lowercased-keys dict (case-insensitive lookup).
    - Empty strings and 'nan' are treated as missing.
    This makes the CSV header flexible (e.g., 'patientId' vs 'patient').
    """
    for n in names:
        v = row_ci.get(n)
        if v is None:
            continue
        s = str(v).strip()
        if s and s.lower() != 'nan':
            return s
    return None


def to_fhir_datetime(s: str, tz_offset="+02:00") -> str:
    """
    Normalize arbitrary local date/time strings to FHIR-compliant dateTime.
    Accepted examples:
      - '24.07.2012 08:24' (dd.MM.yyyy HH:mm)
      - '2012-07-24' (yyyy-MM-dd) → returns date-only (valid FHIR dateTime)
      - Already ISO-ish strings are returned as-is.
    Fallback: now() in UTC (safe default to avoid validator errors).
    """
    s = (s or "").strip()

    # If it's already ISO-8601-ish (includes 'T' and either 'Z' or a timezone offset),
    # trust it — this avoids double-formatting good inputs.
    if s and ("T" in s) and (s.endswith("Z") or "+" in s or "-" in s[10:]):
        return s

    # Try a few common local formats. Add more here if your inputs vary.
    for fmt in ("%d.%m.%Y %H:%M", "%Y-%m-%d", "%d/%m/%Y %H:%M"):
        try:
            dt = datetime.strptime(s, fmt)
            if fmt == "%Y-%m-%d":
                # Date-only is allowed by FHIR; clients interpret as an imprecise datetime.
                return dt.strftime("%Y-%m-%d")
            # Add seconds and a stable offset; for Zurich summer use +02:00 (adjust seasonally if you wish).
            return dt.strftime(f"%Y-%m-%dT%H:%M:00{tz_offset}")
        except ValueError:
            pass

    # Last resort: provide a valid ISO string in UTC. This prevents $validate failures
    # but obviously loses original user-provided timestamp.
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def abs_ref(resource_type: str, ref: str) -> str:
    """
    Convert a relative reference like 'Patient/123' to an absolute reference:
      'http://host:port/fhir/Patient/123'
    If ref is already absolute (http/https/urn:uuid), return as-is.
    If ref is a bare id '123', we prepend the resource type.
    """
    if not ref:
        return None
    if ref.startswith(("http://", "https://", "urn:uuid:")):
        return ref
    if "/" not in ref:
        # Ref like '123' → assume it's an id for the provided resource_type.
        return f"{FHIR_BASE}/{resource_type}/{ref}"
    return f"{FHIR_BASE}/{ref}"

def rel_ref(resource_type: str, ref: str) -> str:
    """
    Always emit relative references:
      - "123" -> "Patient/123"
      - "Patient/123" -> "Patient/123"
      - Already relative stays relative
    """
    if not ref:
        return None
    if "/" not in ref:
        return f"{resource_type}/{ref}"
    return ref


def build_qr(row_ci: dict, questionnaire: str, likert_system: str, n_items: int):
    """
    Build a single QuestionnaireResponse entry from a CSV row (case-insensitive keys).
    Returns a Bundle.entry dict containing:
      - fullUrl (urn:uuid)
      - resource (the QuestionnaireResponse)
      - request (batch operation: POST QuestionnaireResponse)
    """

    CODE_MAP = {"1": "disagree", "2": "neutral", "3": "agree"}
    DISPLAY_MAP = {
        "disagree": "Mostly disagree",
        "neutral": "Not sure",
        "agree": "Mostly agree",
    }

    patient_ref     = get_first_present(row_ci, "patientid", "patient", "subject")
    encounter_ref   = get_first_present(row_ci, "encounterid", "encounter")
    practitioner_id = get_first_present(row_ci, "practitionerid", "author", "practitioner")
    raw_authored    = get_first_present(row_ci, "authored", "date")
    authored        = to_fhir_datetime(raw_authored, tz_offset="+02:00")
    src_ref         = get_first_present(row_ci, "src", "source") or patient_ref

    if not authored:
        authored = datetime.now(timezone.utc).isoformat()

    items = []
    answers_text = []
    for i in range(1, n_items + 1):
        candidates = [f"ans_q{i}", f"ans_q{i:02d}", f"answer_q{i}", f"q{i}"]
        val = get_first_present(row_ci, *candidates)
        if val is None:
            continue
        code = CODE_MAP.get(str(val).strip(), str(val).strip())
        display = DISPLAY_MAP.get(code, code)
        answers_text.append(f"Q{i}: {display}")
        items.append({
            "linkId": f"nreq-q{i}",
            "answer": [{
                "valueCoding": {
                    "system": likert_system,
                    "code": code,
                    "display": display
                }
            }]
        })

    # Create a minimal narrative <div> for best practice compliance
    narrative_html = "<div xmlns='http://www.w3.org/1999/xhtml'><p>QuestionnaireResponse for patient {}</p><ul>{}</ul></div>".format(
        patient_ref or "unknown",
        "".join(f"<li>{t}</li>" for t in answers_text)
    )

    qr = {
        "resourceType": "QuestionnaireResponse",
        "status": "completed",
        "questionnaire": questionnaire,
        "authored": authored,
        "item": items,
        "text": {
            "status": "generated",
            "div": narrative_html
        }
    }
    if patient_ref:
        qr["subject"] = {"reference": rel_ref("Patient", patient_ref)}
    if src_ref:
        qr["source"] = {"reference": rel_ref("Patient", src_ref)}
    if encounter_ref:
        qr["encounter"] = {"reference": rel_ref("Encounter", encounter_ref)}
    if practitioner_id:
        qr["author"] = {"reference": rel_ref("Practitioner", practitioner_id)}

    return {
        "fullUrl": f"urn:uuid:{uuid.uuid4()}",
        "resource": qr,
        "request": {"method": "POST", "url": "QuestionnaireResponse"}
    }


def write_chunk(entries, out_dir, idx):
    """
    Serialize a batch Bundle with the provided entries. Keeps the file naming stable for
    shell loops (nreq_batch_bundle_001.json etc.).
    """
    bundle = {"resourceType": "Bundle", "type": "batch", "entry": entries}
    path = os.path.join(out_dir, f"nreq_batch_bundle_{idx:03d}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(bundle, f, ensure_ascii=False, indent=2)
    return path


def main():
    # CLI with sensible defaults so it’s easy to automate in CI or makefiles.
    ap = argparse.ArgumentParser(description="Create chunked FHIR batch bundles of QuestionnaireResponse from CSV.")
    ap.add_argument("--csv", required=True, default="./input/QuestionnaireResponse.csv", help="Path to CSV (comma/semicolon/tab supported).")
    ap.add_argument("--out", default="output", help="Output directory (default: ./output).")
    ap.add_argument("--chunk-size", type=int, default=250, help="QuestionnaireResponses per bundle (default 250).")
    ap.add_argument("--questionnaire", default="http://example.org/fhir/Questionnaire/NREQ",
                    help="Questionnaire canonical (url|version).")
    ap.add_argument("--likert-system", default="http://example.org/fhir/CodeSystem/nreq-likert-3",
                    help="CodeSystem URL for Likert answers.")
    ap.add_argument("--n-items", type=int, default=17, help="Number of NREQ items (default 17).")
    args = ap.parse_args()

    # Ensure output exists; idempotent and safe.
    os.makedirs(args.out, exist_ok=True)

    # Robust CSV parsing across locales.
    delim = detect_delimiter(args.csv)

    total_rows = 0         # total QRs produced
    chunk_idx = 0          # 1-based chunk counter
    current = []           # in-memory buffer for the current bundle
    out_files = []         # paths of chunks written

    # Read the CSV and produce entries. We normalize headers to lowercase
    # so 'PatientId' or 'patientid' both work.
    with open(args.csv, 'r', encoding='utf-8-sig', newline='') as f:
        reader = csv.DictReader(f, delimiter=delim)
        for row in reader:
            row_ci = {(k or "").strip().lower(): v for k, v in row.items()}
            entry = build_qr(row_ci, args.questionnaire, args.likert_system, args.n_items)
            current.append(entry)
            total_rows += 1

            # Flush when we hit the chunk size to keep memory usage bounded and
            # to avoid oversized POST bodies later.
            if len(current) >= args.chunk_size:
                chunk_idx += 1
                out_files.append(write_chunk(current, args.out, chunk_idx))
                current = []

        # Flush any remainder.
        if current:
            chunk_idx += 1
            out_files.append(write_chunk(current, args.out, chunk_idx))

    # Friendly summary for CI logs or human runs.
    print(f"✅ Wrote {chunk_idx} bundle(s) to '{args.out}', total QuestionnaireResponses: {total_rows}")
    print("💡 POST example (bash):")
    print("  BASE=\"%s\"; for f in %s/nreq_batch_bundle_*.json; do \\"
          % (FHIR_BASE, args.out))
    print("    echo \"→ POST $f\"; \\")
    print("    curl -sS -X POST \"$BASE\" -H \"Content-Type: application/fhir+json\" \\")
    print("      -H \"Accept: application/fhir+json\" -H \"Prefer: return=minimal\" \\")
    print("      --data-binary @\"$f\" || echo \"(error)\"; done")
    for p in out_files[:5]:
        print("  ", p)


if __name__ == "__main__":
    main()