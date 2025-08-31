#!/usr/bin/env python3
"""
PREM-on-FHIR: one CLI to seed synthetic data & talk to HAPI.

Subcommands (short list):
  synthea build                 Build the Synthea Docker image
  synthea run                   Run Synthea and write NDJSON to output/
  fhir wait-ready               Wait until HAPI answers 200 on /metadata
  fhir import                   Submit + poll a bulk $import job
  fhir post-bundle              POST a single Bundle JSON
  fhir post-bundles             POST many Bundle JSON files by pattern
  bundle make-questionnaires    Build a transaction Bundle from CS/VS/Q JSON
  qr export-headers             Export QR header CSV from the HAPI DB (SQL)
  qr make-bundles               Generate QR batch bundles (NREQ/PPNQ dry-run)

The CLI auto-loads your root .env (or ENV_FILE), so you don’t have to
pass env values to every command.

Keep it simple:
- No external AI calls, only deterministic local generation.
- No Docker SDK requirement: we exec `docker` via subprocess.

Author: you + future-you – comments explain intent, not the obvious.
"""

from __future__ import annotations

import argparse
import csv
import glob
import json
import math
import os
import re
import shlex
import subprocess
import sys
import time
import uuid
import random
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
from urllib.parse import parse_qs, urlparse

import requests
from dotenv import load_dotenv

# ---------------------------
# .env loading
# ---------------------------

DEFAULT_BASE = "http://localhost:8080/fhir"

def _find_dotenv(start: Optional[str] = None) -> Optional[str]:
    """
    Search upward from start (or CWD) for a .env file.
    We cap at a few levels to avoid crawling the world.
    """
    d = Path(start or os.getcwd()).resolve()
    for _ in range(8):
        p = d / ".env"
        if p.is_file():
            return str(p)
        if d.parent == d:
            break
        d = d.parent
    return None

def load_env_from_root() -> None:
    """
    Load ENV values once, early.
    Priority: real env > .env values; we do not override existing OS env.
    """
    env_file = os.getenv("ENV_FILE") or _find_dotenv()
    if env_file and Path(env_file).is_file():
        load_dotenv(dotenv_path=env_file, override=False)


# ---------------------------
# small helpers
# ---------------------------

def env_bool(name: str, default: bool) -> bool:
    v = os.getenv(name)
    if v is None:
        return default
    return v.strip().lower() in ("1", "true", "yes", "y", "on")

def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")

def rel_ref(resource_type: str, identifier: str) -> str:
    if not identifier:
        return ""
    s = str(identifier).strip()
    if "/" in s or s.startswith("urn:uuid:") or s.startswith("http"):
        return s
    return f"{resource_type}/{s}"

def die(msg: str, code: int = 1) -> None:
    print(f"❌ {msg}", file=sys.stderr)
    raise SystemExit(code)


# ---------------------------
# HTTP (HAPI)
# ---------------------------

def make_session() -> requests.Session:
    s = requests.Session()
    s.headers.update({"Accept": "application/fhir+json, application/json;q=0.9, */*;q=0.1"})
    token = os.getenv("FHIR_TOKEN")
    if token:
        s.headers["Authorization"] = f"Bearer {token}"
    else:
        user, pw = os.getenv("FHIR_BASIC_USER"), os.getenv("FHIR_BASIC_PASS")
        if user and pw:
            s.auth = (user, pw)
    return s


# ---------------------------
# docker exec (for synthea)
# ---------------------------

def check_docker() -> None:
    try:
        subprocess.run(["docker", "--version"], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except Exception as e:
        die("Docker is not available on PATH. Install Docker Desktop or add it to PATH.", 2)

def run_cmd(cmd: List[str], cwd: Optional[Path] = None) -> int:
    """
    Thin wrapper over subprocess.run so every call is consistent and prints command.
    """
    print("→", " ".join(shlex.quote(x) for x in cmd))
    try:
        cp = subprocess.run(cmd, cwd=str(cwd) if cwd else None)
        return cp.returncode
    except KeyboardInterrupt:
        print("\n(Interrupted)")
        return 130


# ---------------------------
# Command: fhir wait-ready
# ---------------------------

def cmd_wait_ready(args: argparse.Namespace) -> int:
    base = args.base or os.getenv("FHIR_BASE", DEFAULT_BASE)
    verify = env_bool("FHIR_VERIFY_SSL", True)
    s = make_session()
    url = f"{base}/metadata"
    deadline = time.time() + args.timeout
    print(f"Waiting for HAPI at {url} (timeout {args.timeout}s, interval {args.interval}s)…")
    while True:
        try:
            r = s.get(url, timeout=10, verify=verify)
            if r.status_code == 200:
                print("✅ HAPI is ready.")
                return 0
            print(f"… HTTP {r.status_code}, retrying")
        except requests.RequestException as e:
            print(f"… not ready: {e}")
        if time.time() > deadline:
            print("❌ Timed out waiting for HAPI.")
            return 1
        time.sleep(args.interval)


# ---------------------------
# Command: fhir import (bulk $import)
# ---------------------------

def _extract_job_id(resp: requests.Response) -> Optional[str]:
    cl = resp.headers.get("Content-Location")
    if cl:
        q = parse_qs(urlparse(cl).query)
        if "_jobId" in q and q["_jobId"]:
            return q["_jobId"][0]
    m = re.search(r'"jobId"\s*:\s*"([0-9a-f-]+)"', resp.text, re.I)
    if m:
        return m.group(1)
    m = re.search(r'\bID:\s*([0-9a-f-]+)\b', resp.text, re.I)
    if m:
        return m.group(1)
    return None

def cmd_import(args: argparse.Namespace) -> int:
    base = args.base or os.getenv("FHIR_BASE", DEFAULT_BASE)
    verify = env_bool("FHIR_VERIFY_SSL", True)
    poll_interval = args.interval or int(os.getenv("POLL_INTERVAL", "30"))
    params_file = Path(args.params_file)
    params_file.is_file() or die(f"File not found: {params_file}", 2)

    s = make_session()
    url = f"{base}/$import"
    print(f"➡️  Submitting $import to {url} with {params_file}")
    try:
        with params_file.open("rb") as fh:
            r = s.post(
                url,
                data=fh,
                headers={"Content-Type": "application/fhir+json", "Prefer": "respond-async"},
                timeout=60,
                verify=verify,
            )
    except requests.RequestException as e:
        die(f"Submit failed: {e}", 2)

    if r.status_code not in (200, 202):
        die(f"Submit failed: HTTP {r.status_code}\n{r.text}", 2)

    job_id = _extract_job_id(r)
    job_id or die("Could not extract jobId from response.\n" + r.text, 2)

    print(f"✅ Job started: {job_id}")
    poll_url = f"{base}/$import-poll-status?_jobId={job_id}"
    print(f"⏳ Polling every {poll_interval}s: {poll_url}")

    deadline = time.time() + args.timeout_minutes * 60
    while True:
        if time.time() > deadline:
            die("Timed out waiting for import to finish.", 3)
        try:
            pr = s.get(poll_url, timeout=30, verify=verify)
        except requests.RequestException as e:
            print(f"⚠️  Poll error: {e}; retrying…")
            time.sleep(poll_interval)
            continue

        print(f"---- {time.strftime('%H:%M:%S')} ---- [HTTP {pr.status_code}]")
        body = pr.text.strip()
        print(body[:2000] + (" …" if len(body) > 2000 else ""))

        if pr.status_code == 202:
            time.sleep(poll_interval)
            continue
        if pr.status_code == 200:
            if re.search(r'"status"\s*:\s*"FAILED"', body, re.I) or "Job is in FAILED state" in body:
                die("Import FAILED.", 4)
            print("✅ Import completed.")
            return 0

        die("Unexpected poll response.", 5)


# ---------------------------
# Command: fhir post-bundle / post-bundles
# ---------------------------

def post_bundle_file(bundle_file: Path, base: str, verify_ssl: bool, accept: bool, prefer_minimal: bool,
                     timeout: int, log_dir: Optional[Path]) -> bool:
    s = make_session()
    headers = {"Content-Type": "application/fhir+json"}
    if accept:
        headers["Accept"] = "application/fhir+json"
    if prefer_minimal:
        headers["Prefer"] = "return=minimal"

    with bundle_file.open("rb") as fh:
        try:
            r = s.post(base, data=fh, headers=headers, timeout=timeout, verify=verify_ssl)
        except requests.RequestException as e:
            print(f"✗ ERROR: {bundle_file.name} — {e}")
            if log_dir:
                log_dir.mkdir(parents=True, exist_ok=True)
                (log_dir / f"{bundle_file.name}.error.txt").write_text(str(e))
            return False

    if 200 <= r.status_code < 300:
        print(f"✓ {bundle_file.name} — HTTP {r.status_code}")
        return True

    print(f"✗ ERROR {r.status_code} for {bundle_file.name}")
    if log_dir:
        log_dir.mkdir(parents=True, exist_ok=True)
        (log_dir / f"{bundle_file.name}.response.txt").write_text(r.text)
    # Try to show OperationOutcome summary inline
    try:
        obj = r.json()
        if obj.get("resourceType") == "OperationOutcome":
            for issue in obj.get("issue", []):
                sev = issue.get("severity", "?")
                code = issue.get("code", "?")
                diag = issue.get("diagnostics") or (issue.get("details") or {}).get("text", "")
                print(f"  * {sev} {code}: {diag}")
    except Exception:
        pass
    return False

def cmd_post_bundle(args: argparse.Namespace) -> int:
    base = args.base or os.getenv("FHIR_BASE", DEFAULT_BASE)
    verify = env_bool("FHIR_VERIFY_SSL", True)
    bundle_file = Path(args.bundle_file)
    bundle_file.is_file() or die(f"File not found: {bundle_file}", 2)
    ok = post_bundle_file(
        bundle_file, base, verify, accept=True, prefer_minimal=True,
        timeout=args.timeout, log_dir=Path(args.log_dir) if args.log_dir else None
    )
    return 0 if ok else 2

def cmd_post_bundles(args: argparse.Namespace) -> int:
    base = args.base or os.getenv("FHIR_BASE", DEFAULT_BASE)
    verify = env_bool("FHIR_VERIFY_SSL", True)
    files = sorted(Path().glob(args.pattern))
    if not files:
        print(f"No files matched pattern: {args.pattern}")
        return 0
    print(f"Target FHIR base: {base}")
    print(f"Found {len(files)} bundle file(s).")
    successes = 0
    for f in files:
        ok = post_bundle_file(
            f, base, verify,
            accept=bool(1 if args.accept else 0),
            prefer_minimal=bool(1 if args.prefer_minimal else 0),
            timeout=args.timeout,
            log_dir=Path(args.log_dir) if args.log_dir else None,
        )
        successes += int(ok)
    print(f"Done. {successes}/{len(files)} succeeded.")
    return 0 if successes == len(files) else 2


# ---------------------------
# Command: bundle make-questionnaires
# (CodeSystem/ValueSet/Questionnaire → transaction Bundle)
# ---------------------------

ORDER = {"CodeSystem": 0, "ValueSet": 1, "Questionnaire": 2}
ALLOWED = set(ORDER.keys())

def _load_resources(indir: Path) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for p in sorted(indir.glob("*.json")):
        try:
            obj = json.loads(p.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"Skipping {p.name}: invalid JSON ({e})", file=sys.stderr)
            continue
        if isinstance(obj, dict) and obj.get("resourceType") in ALLOWED:
            out.append(obj)
    return out

def _req_method(res: Dict[str, Any], mode: str) -> str:
    return "PUT" if (mode == "put" or (mode == "auto" and res.get("id"))) else "POST"

def _req_url(res: Dict[str, Any]) -> str:
    rt = res["resourceType"]
    rid = res.get("id")
    return f"{rt}/{rid}" if rid else rt

def _tx_entry(res: Dict[str, Any], mode: str) -> Dict[str, Any]:
    return {
        "fullUrl": f"urn:uuid:{uuid.uuid4()}",
        "resource": res,
        "request": {"method": _req_method(res, mode), "url": _req_url(res)},
    }

def cmd_make_questionnaires(args: argparse.Namespace) -> int:
    indir = Path(args.indir)
    out = Path(args.outfile)
    out.parent.mkdir(parents=True, exist_ok=True)
    res = _load_resources(indir)
    if not res:
        die(f"No CodeSystem/ValueSet/Questionnaire resources in {indir}", 2)
    res = sorted(res, key=lambda r: (ORDER.get(r.get("resourceType"), 99), r.get("id") or ""))
    bundle = {"resourceType": "Bundle", "type": "transaction", "entry": [_tx_entry(r, args.method) for r in res]}
    out.write_text(json.dumps(bundle, indent=2), encoding="utf-8")
    print(f"Wrote transaction Bundle with {len(res)} resources → {out}")
    return 0


# ---------------------------
# Command: qr export-headers  (SQL → CSV)
# ---------------------------

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
  COALESCE(enc_date.period_end, enc_date.period_start, NOW()) AS authored,
  'Patient/' || pat.pat_logical_id  AS src
FROM enc
JOIN enc_patient ON enc.res_id = enc_patient.enc_res_id
JOIN pat         ON pat.res_id = enc_patient.pat_res_id
LEFT JOIN enc_prac_one ep ON enc.res_id = ep.enc_res_id
LEFT JOIN prac          ON prac.res_id = ep.prac_res_id
LEFT JOIN enc_date      ON enc.res_id = enc_date.enc_res_id
ORDER BY patientId, encounterId;
"""

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


# ---------------------------
# Command: qr make-bundles (NREQ/PPNQ dry-run)
# ---------------------------

NREQ_Q = {
  "resourceType": "Questionnaire",
  "url": "http://example.org/fhir/Questionnaire/NREQ",
  "version": "1.0",
  "name": "NREQ",
  "title": "Neurorehabilitation Experience Questionnaire (NREQ)",
  "status": "active",
  "item": [{"linkId": f"nreq-q{i}", "type": "choice"} for i in range(1, 18)]
}
NREQ_LIKERT_SYSTEM = "http://example.org/fhir/CodeSystem/nreq-likert-3"
NREQ_CODE = {1: "disagree", 2: "neutral", 3: "agree"}
NREQ_DISP = {1: "Mostly disagree", 2: "Not sure", 3: "Mostly agree"}

PPNQ_Q = {
  "resourceType": "Questionnaire",
  "url": "http://example.org/fhir/Questionnaire/NeuroRehabPREM",
  "version": "1.0",
  "name": "NeuroRehabPREM",
  "title": "Patient Reported Experience Measure – Neurorehabilitation",
  "status": "active",
  "item": [
    {"linkId": "ppnq-q1", "type": "string"},
    {"linkId": "ppnq-q2", "type": "string"},
    {"linkId": "ppnq-q3a", "type": "string"},
    {"linkId": "ppnq-q3b", "type": "string"},
    {"linkId": "ppnq-q4", "type": "string"},
    {"linkId": "ppnq-q5", "type": "string"},
    {"linkId": "ppnq-q6", "type": "string"},
    {"linkId": "ppnq-q7", "type": "string"},
    {"linkId": "ppnq-q8", "type": "string"},
    {"linkId": "ppnq-q9", "type": "choice"},
    {"linkId": "ppnq-q9-text", "type": "string"},
  ]
}
NPS_SYSTEM = "http://example.org/fhir/CodeSystem/nps-scale"

HEADER_ALIASES = {
    "patient": ["patient","patientid","patient_id","subject","subjectid"],
    "encounter": ["encounter","encounterid","encounter_id"],
    "author": ["author","authorid","author_id","practitioner","practitionerid"],
    "source": ["source","sourceid","source_id"],
    "authored": ["authored","authoredon","date"],
    "qr_id": ["qr_id","questionnaireresponseid","qrid"],
}

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
    if s:
        for fmt in ("%Y-%m-%d", "%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S",
                    "%Y-%m-%dT%H:%M", "%Y-%m-%dT%H:%M:%S"):
            try:
                return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc).isoformat()
            except Exception:
                pass
    return now_iso()

def _read_header_csv(path: Path) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    with path.open("r", encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f, delimiter=_detect_delim(path)):
            rows.append(_norm_keys(row))
    return rows

def _nreq_answers(rng, questionnaire, likert_probs: Optional[Tuple[float,float,float]] = None) -> List[Dict[str, Any]]:
    """
    Generate NREQ answers. If likert_probs is provided, it should be a 3-tuple
    of probabilities for values 1,2,3 and will be normalized automatically.
    """
    probs = likert_probs or (1/3, 1/3, 1/3)
    total = sum(probs)
    p1, p2, p3 = (probs[0]/total, probs[1]/total, probs[2]/total)

    out = []
    for it in questionnaire.get("item", []):
        if not it.get("linkId","").startswith("nreq-q"):
            continue
        r = rng.random()
        if r < p1:
            v = 1
        elif r < p1 + p2:
            v = 2
        else:
            v = 3
        out.append({
            "linkId": it["linkId"],
            "valueCoding": {"system": NREQ_LIKERT_SYSTEM, "code": NREQ_CODE[v], "display": NREQ_DISP[v]}
        })
    return out

def _parse_likert_dist(s: Optional[str]) -> Optional[Tuple[float,float,float]]:
    if not s:
        return None
    parts = [float(x) for x in s.split(",")]
    if len(parts) != 3:
        die("--likert-dist must be three comma-separated numbers, e.g. 0.2,0.5,0.3", 2)
    total = sum(parts)
    if total <= 0:
        die("likert distribution must sum to > 0", 2)
    return (parts[0]/total, parts[1]/total, parts[2]/total)

def _ppnq_schema_prompt(questionnaire: Dict[str, Any]) -> str:
    req = [it["linkId"] for it in questionnaire.get("item", [])]
    return "\n".join([
        "You write realistic, succinct patient feedback for a neurorehabilitation PREM.",
        "Return a SINGLE JSON object with this shape:",
        "{",
        '  "answers": [',
        '    {"linkId": "<id>", "valueString": "<short sentence>"},',
        '    ...',
        '    {"linkId": "ppnq-q9", "valueCoding": {"system": "http://example.org/fhir/CodeSystem/nps-scale", "code": "<0-10 string>", "display": "<same>"}}',
        '    {"linkId": "ppnq-q9-text", "valueString": "<one-sentence reason>"}',
        "  ]",
        "}",
        "",
        "Rules:",
        "- Include EVERY required linkId exactly once: " + ", ".join(req),
        "- For ppnq-q1..q8: one concise sentence each (max ~25 words).",
        "- For ppnq-q9: integer 0..10 that matches your sentiment.",
        "- Output ONLY the JSON (no markdown).",
    ])

def _ppnq_user_context(row: Dict[str,Any]) -> str:
    pid = _pick(row, HEADER_ALIASES["patient"]) or "unknown"
    eid = _pick(row, HEADER_ALIASES["encounter"]) or "unknown"
    authored = _to_fhir_dt(_pick(row, HEADER_ALIASES["authored"]))
    return f"Patient={pid} Encounter={eid} Authored={authored}"

def _validate_ppnq_answers(obj: Dict[str, Any]) -> List[Dict[str, Any]]:
    if not isinstance(obj, dict) or "answers" not in obj or not isinstance(obj["answers"], list):
        die("LLM output must be a JSON object with an 'answers' array.", 2)
    out = []
    seen = set()
    required = {"ppnq-q1","ppnq-q2","ppnq-q3a","ppnq-q3b","ppnq-q4","ppnq-q5","ppnq-q6","ppnq-q7","ppnq-q8","ppnq-q9","ppnq-q9-text"}
    for a in obj["answers"]:
        if not isinstance(a, dict) or "linkId" not in a:
            continue
        lid = a["linkId"]
        if lid in seen:
            continue
        seen.add(lid)
        if "valueString" in a and isinstance(a["valueString"], str):
            out.append({"linkId": lid, "valueString": a["valueString"]})
        elif "valueCoding" in a and isinstance(a["valueCoding"], dict):
            vc = a["valueCoding"]
            code = str(vc.get("code"))
            disp = str(vc.get("display") or code)
            out.append({"linkId": lid, "valueCoding": {"system": NPS_SYSTEM, "code": code, "display": disp}})
    missing = sorted(required - {a["linkId"] for a in out})
    if missing:
        die("LLM missed required answers: " + ", ".join(missing), 2)
    # coerce NPS 0..10
    for a in out:
        if a["linkId"] == "ppnq-q9" and "valueCoding" in a:
            try:
                nps = max(0, min(10, int(a["valueCoding"]["code"])))
            except Exception:
                nps = 7
            a["valueCoding"] = {"system": NPS_SYSTEM, "code": str(nps), "display": str(nps)}
    return out

def _ppnq_answers_llm(questionnaire: Dict[str,Any], row: Dict[str,Any], model: str, temperature: float, max_retries: int) -> List[Dict[str,Any]]:
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        die("OPENAI_API_KEY is required when using --llm. Put it in your .env.", 2)
    url = "https://api.openai.com/v1/chat/completions"
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}

    prompt = _ppnq_schema_prompt(questionnaire) + "\n\n" + _ppnq_user_context(row)
    payload = {
        "model": model,
        "messages": [
            {"role":"system","content":"You are a careful medical scribe that follows JSON schemas exactly."},
            {"role":"user","content":prompt},
        ],
        "temperature": float(temperature),
        "response_format": {"type":"json_object"},
    }

    last = None
    for attempt in range(max(1, int(max_retries))):
        try:
            r = requests.post(url, headers=headers, json=payload, timeout=60)
            if r.status_code == 200:
                content = r.json()["choices"][0]["message"]["content"]
                return _validate_ppnq_answers(json.loads(content))
            last = RuntimeError(f"OpenAI HTTP {r.status_code}: {r.text[:2000]}")
        except Exception as e:
            last = e
        time.sleep(1.5 * (attempt + 1))
    raise last or RuntimeError("LLM generation failed.")

def _ppnq_answers_dry(rng) -> List[Dict[str, Any]]:
    topics = {
        "ppnq-q1":"access to services", "ppnq-q2":"meeting my needs",
        "ppnq-q3a":"seeing same clinicians", "ppnq-q3b":"information sharing",
        "ppnq-q4":"coordination", "ppnq-q5":"safety during therapies",
        "ppnq-q6":"listening to preferences", "ppnq-q7":"self-management support",
        "ppnq-q8":"trust in the team",
    }
    stems = ["Overall,","In general,","I felt","It seemed","From my perspective,"]
    traits = [" communication was clear"," care was coordinated"," I was listened to"," safety was emphasised"," goals were understood"]
    answers = [{"linkId": lid, "valueString": f"{rng.choice(stems)}{rng.choice(traits)} about {topic}."}
               for lid,topic in topics.items()]
    nps = rng.randint(0,10)
    answers.append({"linkId":"ppnq-q9","valueCoding":{"system":NPS_SYSTEM,"code":str(nps),"display":str(nps)}})
    reason = "Excellent teamwork." if nps>=9 else ("Good overall with some waits." if nps>=7 else "Several issues affected my experience.")
    answers.append({"linkId":"ppnq-q9-text","valueString":reason})
    return answers

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

def cmd_qr_make_bundles(args: argparse.Namespace) -> int:
    rng = random.Random(args.seed)
    header_rows = _read_header_csv(Path(args.csv))
    if not header_rows:
        die("No rows in header CSV.", 2)

    # choose questionnaire
    if args.mode == "nreq":
        questionnaire = json.loads(Path(args.questionnaire_file).read_text(encoding="utf-8")) if args.questionnaire_file else NREQ_Q
    else:
        questionnaire = json.loads(Path(args.questionnaire_file).read_text(encoding="utf-8")) if args.questionnaire_file else PPNQ_Q
    questionnaire_url = args.questionnaire_url or questionnaire.get("url")

    resources: List[Dict[str, Any]] = []
    if args.mode == "nreq":
        probs = _parse_likert_dist(args.likert_dist)
        for row in header_rows:
            answers = _nreq_answers(rng, questionnaire, probs)
            resources.append(_qr_from_header(args.mode, row, questionnaire, questionnaire_url, answers))

    else:  # ppnq
        for row in header_rows:
            if args.llm and not args.dry_run:
                answers = _ppnq_answers_llm(
                    questionnaire, row,
                    model=args.llm_model,
                    temperature=args.llm_temperature,
                    max_retries=args.llm_max_retries,
                )
            else:
                answers = _ppnq_answers_dry(rng)
            resources.append(_qr_from_header(args.mode, row, questionnaire, questionnaire_url, answers))

    # write chunked bundles
    out_dir = Path(args.out); out_dir.mkdir(parents=True, exist_ok=True)
    prefix = args.mode
    total = len(resources); chunk = max(1, args.chunk_size)
    files: List[Path] = []
    for i in range(math.ceil(total/chunk)):
        batch = resources[i*chunk:(i+1)*chunk]
        bundle = _bundle_entries(batch)
        p = out_dir / f"{prefix}_batch_bundle_{i+1:03d}.json"
        p.write_text(json.dumps(bundle, indent=2), encoding="utf-8")
        files.append(p)
    print(f"Created {total} QuestionnaireResponses in {len(files)} file(s):")
    for p in files: print(f" - {p}")
    return 0


# ---------------------------
# Command: synthea build/run
# ---------------------------

def cmd_synthea_build(args: argparse.Namespace) -> int:
    check_docker()
    context = Path(args.context).resolve()
    context.is_dir() or die(f"Build context not found: {context}", 2)
    tag = args.tag
    cmd = ["docker","build","-t",tag,str(context)]
    return run_cmd(cmd)

def cmd_synthea_run(args: argparse.Namespace) -> int:
    """
    We run the Synthea image and map output directory from your repo.
    We pass environment knobs expected by your Dockerfile entrypoint.
    """
    check_docker()
    image = args.image
    out_dir = Path(args.output).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    envs = {
        "POPULATION": args.population,
        "AGE_RANGE": args.age_range,
        "KEEP_FILE": args.keep_file,
        "EXTRA_ARGS": args.extra_args or "",
    }
    cmd = ["docker","run","--rm","-it","-v",f"{str(out_dir)}:/output"]
    for k,v in envs.items():
        if v is not None:
            cmd += ["-e", f"{k}={v}"]
    cmd += [image]
    return run_cmd(cmd)


# ---------------------------
# CLI wiring
# ---------------------------

def main() -> int:
    load_env_from_root()
    p = argparse.ArgumentParser(prog="cli", description="PREM-on-FHIR helper CLI")
    sub = p.add_subparsers(dest="cmd", required=True)

    # synthea
    psb = sub.add_parser("synthea", help="Synthea utilities")
    ssub = psb.add_subparsers(dest="scmd", required=True)

    pbuild = ssub.add_parser("build", help="Build Synthea Docker image")
    pbuild.add_argument("--context", default="01-data-generation/synthea", help="Docker build context folder")
    pbuild.add_argument("--tag", default="syntheadocker", help="Image tag to build")
    pbuild.set_defaults(func=cmd_synthea_build)

    prun = ssub.add_parser("run", help="Run Synthea and write NDJSON into output directory")
    prun.add_argument("--image", default="syntheadocker", help="Image tag to run")
    prun.add_argument("--output", default="01-data-generation/synthea/output", help="Host output directory")
    prun.add_argument("--population", default=os.getenv("POPULATION","5"))
    prun.add_argument("--age-range", default=os.getenv("AGE_RANGE","18-100"))
    prun.add_argument("--keep-file", default=os.getenv("KEEP_FILE","keep_neuro.json"))
    prun.add_argument("--extra-args", default=os.getenv("EXTRA_ARGS","--exporter.fhir.bulk_data=true --exporter.baseDirectory=/output --generate.only_alive_patients=true --generate.max_attempts_to_keep_patient=20000"))
    prun.set_defaults(func=cmd_synthea_run)

    # fhir
    pfhir = sub.add_parser("fhir", help="FHIR server actions")
    fsub = pfhir.add_subparsers(dest="fcmd", required=True)

    pready = fsub.add_parser("wait-ready", help="Wait for HAPI to respond 200")
    pready.add_argument("--base", default=os.getenv("FHIR_BASE", DEFAULT_BASE))
    pready.add_argument("--interval", type=int, default=3)
    pready.add_argument("--timeout", type=int, default=120, help="seconds")
    pready.set_defaults(func=cmd_wait_ready)

    pimp = fsub.add_parser("import", help="Submit + poll a bulk $import job")
    pimp.add_argument("params_file", help="Parameters JSON")
    pimp.add_argument("--base", default=os.getenv("FHIR_BASE", DEFAULT_BASE))
    pimp.add_argument("--interval", type=int, default=None, help="poll seconds (default: POLL_INTERVAL or 30)")
    pimp.add_argument("--timeout-minutes", type=int, default=60)
    pimp.set_defaults(func=cmd_import)

    ppost1 = fsub.add_parser("post-bundle", help="POST a single FHIR Bundle (transaction/batch)")
    ppost1.add_argument("bundle_file")
    ppost1.add_argument("--base", default=os.getenv("FHIR_BASE", DEFAULT_BASE))
    ppost1.add_argument("--timeout", type=int, default=120)
    ppost1.add_argument("--log-dir", default=None)
    ppost1.set_defaults(func=cmd_post_bundle)

    ppostn = fsub.add_parser("post-bundles", help="POST many Bundle JSON files by glob pattern")
    ppostn.add_argument("--pattern", default="**/*_bundle*.json")
    ppostn.add_argument("--base", default=os.getenv("FHIR_BASE", DEFAULT_BASE))
    ppostn.add_argument("--timeout", type=int, default=600)
    ppostn.add_argument("--accept", action="store_true", default=True)
    ppostn.add_argument("--prefer-minimal", action="store_true", default=True)
    ppostn.add_argument("--log-dir", default="./curl-logs")
    ppostn.set_defaults(func=cmd_post_bundles)

    # bundle
    pb = sub.add_parser("bundle", help="Bundle utilities")
    bsub = pb.add_subparsers(dest="bcmd", required=True)

    pmq = bsub.add_parser("make-questionnaires", help="Make a transaction Bundle from CodeSystem/ValueSet/Questionnaire JSON files")
    pmq.add_argument("--indir", required=True, help="Folder with JSON resources")
    pmq.add_argument("--outfile", required=True, help="Output file path")
    pmq.add_argument("--method", choices=["auto","put","post"], default="auto")
    pmq.set_defaults(func=cmd_make_questionnaires)

    # qr
    pqr = sub.add_parser("qr", help="QuestionnaireResponse helpers")
    qsub = pqr.add_subparsers(dest="qcmd", required=True)

    pqrex = qsub.add_parser("export-headers", help="Run SQL against HAPI DB and write header CSV")
    pqrex.add_argument("--host", default=None)
    pqrex.add_argument("--port", default=None)
    pqrex.add_argument("--name", default=None)
    pqrex.add_argument("--user", default=None)
    pqrex.add_argument("--passwd", default=None)
    pqrex.add_argument("--sql", default=None, help="Optional path to a custom SQL file")
    pqrex.add_argument("--outdir", default="03-elt/nlp_pipeline/input")
    pqrex.set_defaults(func=cmd_qr_export_headers)

    pqrmk = qsub.add_parser("make-bundles", help="Generate QR batch bundles (NREQ / PPNQ dry-run)")
    pqrmk.add_argument("--mode", choices=["nreq","ppnq"], required=True)
    pqrmk.add_argument("--csv", required=True, help="Header CSV produced by export-headers")
    pqrmk.add_argument("--out", default="01-data-generation/synthea/output/qr")
    pqrmk.add_argument("--chunk-size", type=int, default=250)
    pqrmk.add_argument("--questionnaire-file", default=None)
    pqrmk.add_argument("--questionnaire-url", default=None)
    pqrmk.add_argument("--seed", type=int, default=None)
    pqrmk.set_defaults(func=cmd_qr_make_bundles)
    pqrmk.add_argument("--likert-dist", default=None, help="NREQ only: probs for 1,2,3 e.g. 0.2,0.5,0.3")
    pqrmk.add_argument("--dry-run", action="store_true", help="PPNQ only: generate placeholder text (no LLM)")
    pqrmk.add_argument("--llm", action="store_true", help="PPNQ only: call OpenAI for text answers (needs OPENAI_API_KEY)")

    # optional LLM tuning (env-backed defaults)
    pqrmk.add_argument("--llm-model", default=os.getenv("LLM_MODEL", "gpt-4o-mini"))
    pqrmk.add_argument("--llm-temperature", type=float, default=float(os.getenv("LLM_TEMPERATURE", "0.6")))
    pqrmk.add_argument("--llm-max-retries", type=int, default=int(os.getenv("LLM_MAX_RETRIES", "3")))

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
