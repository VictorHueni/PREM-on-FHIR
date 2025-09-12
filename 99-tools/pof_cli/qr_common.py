#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import os
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional
from .utils import die, now_iso, rel_ref


HEADER_ALIASES = {
    "patient": ["patient","patientid","patient_id","subject","subjectid"],
    "encounter": ["encounter","encounterid","encounter_id"],
    "author": ["author","authorid","author_id","practitioner","practitionerid"],
    "source": ["source","sourceid","source_id"],
    "authored": ["authored","authoredon","date"],
    "qr_id": ["qr_id","questionnaireresponseid","qrid"],
}


QR_SQL = """
WITH enc AS (
  SELECT e.res_id, COALESCE(fi.forced_id, e.fhir_id) AS enc_logical_id
  FROM   hfj_resource e
  LEFT JOIN hfj_forced_id fi ON fi.resource_pid = e.res_id
  WHERE  e.res_type = 'Encounter' AND e.res_deleted_at IS NULL
),
enc_patient AS (
  SELECT l.src_resource_id AS enc_res_id, l.target_resource_id AS pat_res_id
  FROM   hfj_res_link l
  JOIN   hfj_resource r ON r.res_id = l.src_resource_id
  WHERE  r.res_type = 'Encounter'
    AND  l.target_resource_type = 'Patient'
    AND  l.src_path IN ('Encounter.subject','Encounter.patient')
),
pat AS (
  SELECT p.res_id, COALESCE(fp.forced_id, p.fhir_id) AS pat_logical_id
  FROM   hfj_resource p
  LEFT JOIN hfj_forced_id fp ON fp.resource_pid = p.res_id
  WHERE  p.res_type = 'Patient' AND p.res_deleted_at IS NULL
),
enc_prac_one AS (
  SELECT DISTINCT ON (l.src_resource_id)
         l.src_resource_id AS enc_res_id,
         l.target_resource_id AS prac_res_id
  FROM   hfj_res_link l
  JOIN   hfj_resource r ON r.res_id = l.src_resource_id
  WHERE  r.res_type = 'Encounter'
    AND  l.target_resource_type = 'Practitioner'
    AND  l.src_path = 'Encounter.participant.individual'
  ORDER BY l.src_resource_id, l.target_resource_id
),
prac AS (
  SELECT pr.res_id, COALESCE(fpr.forced_id, pr.fhir_id) AS prac_logical_id
  FROM   hfj_resource pr
  LEFT JOIN hfj_forced_id fpr ON fpr.resource_pid = pr.res_id
  WHERE  pr.res_type = 'Practitioner' AND pr.res_deleted_at IS NULL
),
enc_date AS (
  SELECT d.res_id AS enc_res_id, d.sp_value_high AS period_end, d.sp_value_low AS period_start
  FROM   hfj_spidx_date d
  JOIN   hfj_resource r ON r.res_id = d.res_id
  WHERE  r.res_type = 'Encounter' AND d.sp_name = 'date'
)
SELECT
  'Patient/'   || pat.pat_logical_id AS patientId,
  'Encounter/' || enc.enc_logical_id AS encounterId,
  CASE WHEN prac.prac_logical_id IS NOT NULL
       THEN 'Practitioner/' || prac.prac_logical_id
       ELSE NULL END        AS practitionerId,
  TO_CHAR(COALESCE(enc_date.period_end, enc_date.period_start, NOW()) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS authored,
  'Patient/' || pat.pat_logical_id  AS src
FROM enc
JOIN enc_patient ON enc.res_id = enc_patient.enc_res_id
JOIN pat         ON pat.res_id = enc_patient.pat_res_id
LEFT JOIN enc_prac_one ep ON enc.res_id = ep.enc_res_id
LEFT JOIN prac          ON prac.res_id = ep.prac_res_id
LEFT JOIN enc_date      ON enc.res_id = enc_date.enc_res_id
ORDER BY patientId, encounterId;
"""


# ---------------------------
# Command: qr make-bundles (NREQ/PPNQ dry-run)
# ---------------------------

def _detect_delim(p: Path) -> str:
    line = p.read_text(encoding="utf-8", errors="ignore").splitlines()[0] if p.exists() else ""
    for cand in (",",";","\t","|"):
        if cand in line:
            return cand
    return ","

def _norm_keys(row: Dict[str, Any]) -> Dict[str, Any]:
    return {(k or "").strip().lower(): v for k,v in row.items()}

def _pick(row: Dict[str, Any], keys: List[str], default: str = "") -> str:
    for k in keys:
        v = row.get(k)
        if v is not None and str(v).strip():
            return str(v).strip()
    return default

def _to_fhir_dt(s: Optional[str]) -> str:
    if not s:
        return now_iso()
    s = str(s).strip()

    # 1) Best-effort ISO 8601 (handles 'YYYY-MM-DD HH:MM:SS[.fff][+HH:MM]', '...T...', and 'Z')
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).isoformat()
    except Exception:
        pass

    # 2) Common fallbacks (with and without timezone / microseconds)
    fmts = [
        "%Y-%m-%d",
        "%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S.%f",
        "%Y-%m-%dT%H:%M", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%d %H:%M%z", "%Y-%m-%d %H:%M:%S%z", "%Y-%m-%d %H:%M:%S.%f%z",
        "%Y-%m-%dT%H:%M%z", "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S.%f%z",
    ]
    for fmt in fmts:
        try:
            dt = datetime.strptime(s, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc).isoformat()
        except Exception:
            continue

    # 3) Unix epoch seconds (optional)
    if re.fullmatch(r"\d{10}(\.\d+)?", s):
        dt = datetime.fromtimestamp(float(s), tz=timezone.utc)
        return dt.isoformat()

    # Last resort
    return now_iso()

def _read_header_csv(path: Path) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    with path.open("r", encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f, delimiter=_detect_delim(path)):
            rows.append(_norm_keys(row))
    return rows
  
  
  
# ---------------------------
# Command: qr export-headers  (SQL → CSV)
# ---------------------------

def cmd_qr_export_headers(args: argparse.Namespace) -> int:
    """
    We read DB creds from either explicit flags or env. Defaults favour your OLTP (HAPI) DB.
    """
    try:
        import psycopg2, psycopg2.extras
    except Exception:
        die("psycopg2-binary is required. Install with: pip install -r tools/requirements-cli.txt", 2)

    # Flag → Env (-> sensible default)
    host = args.host or os.getenv("DB_HOST") or os.getenv("OLTP_DB_HOST") or "localhost"
    port = args.port or os.getenv("DB_PORT") or os.getenv("OLTP_DB_PORT_HOST") or "5432"
    name = args.name or os.getenv("DB_NAME") or os.getenv("OLTP_DB_NAME") or "prem_on_fhir"
    user = args.user or os.getenv("DB_USER") or os.getenv("OLTP_DB_USER") or "admin"
    pw   = args.passwd or os.getenv("DB_PASS") or os.getenv("OLTP_DB_PASSWORD") or "admin"
    sql  = Path(args.sql).read_text(encoding="utf-8") if args.sql else QR_SQL

    out_dir = Path(args.outdir); out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / "QuestionnaireResponse-Header.csv"

    print(f"DB: {user}@{host}:{port}/{name}")
    conn = psycopg2.connect(host=host, port=port, dbname=name, user=user, password=pw)
    cur = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
    cur.execute(sql)
    rows = cur.fetchall()
    headers = [d.name for d in cur.description]
    with out_file.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(headers); w.writerows(rows)
    cur.close(); conn.close()
    print(f"Wrote {len(rows)} rows → {out_file}")
    return 0
  
  
def _qr_from_header(mode: str,
                    row: Dict[str, Any],
                    questionnaire: Dict[str, Any],
                    questionnaire_url: str,
                    answers: List[Dict[str, Any]]) -> Dict[str, Any]:
    # pick header fields
    patient   = _pick(row, HEADER_ALIASES["patient"])
    encounter = _pick(row, HEADER_ALIASES["encounter"])
    author    = _pick(row, HEADER_ALIASES["author"])
    source    = _pick(row, HEADER_ALIASES["source"]) or patient
    authored  = _to_fhir_dt(_pick(row, HEADER_ALIASES["authored"]))
    qr_id     = _pick(row, HEADER_ALIASES["qr_id"]) or str(uuid.uuid4())

    # index answers by linkId (keep one copy WITH linkId for narrative, and
    # one copy WITHOUT for FHIR item.answer[] payload)
    by_link_full: Dict[str, List[Dict[str, Any]]] = {}
    by_link_stripped: Dict[str, List[Dict[str, Any]]] = {}
    for a in answers:
        lid = a.get("linkId")
        if not lid:
            continue
        by_link_full.setdefault(lid, []).append(a)
        by_link_stripped.setdefault(lid, []).append({k: v for k, v in a.items() if k != "linkId"})

    # Build human-readable narrative lines in questionnaire order
    def _line(a: Dict[str, Any]) -> str:
        if "valueCoding" in a:
            disp = a["valueCoding"].get("display") or a["valueCoding"].get("code")
            return f"{a['linkId']}: {disp}"
        if "valueString" in a:
            return f"{a['linkId']}: {a['valueString'][:80]}"
        if "valueInteger" in a:
            return f"{a['linkId']}: {a['valueInteger']}"
        return f"{a.get('linkId','?')}: …"

    lines: List[str] = []
    for it in questionnaire.get("item", []):
        lid = it.get("linkId")
        if lid and lid in by_link_full and by_link_full[lid]:
            lines.append(_line(by_link_full[lid][0]))

    # FHIR Narrative (valid XHTML)
    narrative_html = (
        "<div xmlns=\"http://www.w3.org/1999/xhtml\">"
        f"<p><b>{mode.upper()} QR</b></p>"
        "<p>" + "<br/>".join(lines) + "</p>"
        "</div>"
    )

    # Build QR
    items = []
    for it in questionnaire.get("item", []):
        lid = it.get("linkId")
        if lid in by_link_stripped:
            items.append({"linkId": lid, "answer": by_link_stripped[lid]})

    qr = {
        "resourceType": "QuestionnaireResponse",
        "id": qr_id,
        "status": "completed",
        "questionnaire": questionnaire_url or questionnaire.get("url"),
        "subject":   {"reference": rel_ref("Patient", patient)}       if patient   else None,
        "encounter": {"reference": rel_ref("Encounter", encounter)}   if encounter else None,
        "author":    {"reference": rel_ref("Practitioner", author)}   if author    else None,
        "source":    {"reference": rel_ref("Patient", source)}        if source    else None,
        "authored": authored,
        "text": {"status": "generated", "div": narrative_html},
        "item": items,
    }
    # drop None
    return {k: v for k, v in qr.items() if v is not None}


def _bundle_entries(resources: List[Dict[str, Any]]) -> Dict[str, Any]:
    return {
        "resourceType": "Bundle",
        "type": "batch",
        "entry": [{"fullUrl": f"urn:uuid:{uuid.uuid4()}",
                   "resource": r,
                   "request": {"method": "POST", "url": r["resourceType"]}} for r in resources]
    }

