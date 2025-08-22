#!/usr/bin/env python3
"""
export_qr_headers.py

Connect to HAPI FHIR DB, execute the questionnaire header query,
and save results to CSV for QR generation.

Loads DB_* credentials from a .env file if present.
"""

import csv
import os
from pathlib import Path

import psycopg2
import psycopg2.extras
from dotenv import load_dotenv

# ---- Load .env ----
env_file = ".env"
if Path(env_file).exists():
    load_dotenv(env_file)

# ---- DB connection config ----
DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "hapi")
DB_USER = os.getenv("DB_USER", "hapi")
DB_PASS = os.getenv("DB_PASS", "hapi")

OUT_DIR = Path("./input")
OUT_FILE = OUT_DIR / "QuestionnaireResponse-Header.csv"

SQL = """
-- Select Questionnaire header
WITH enc AS (
  SELECT e.res_id,
         COALESCE(fi.forced_id, e.res_id::text) AS enc_id
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
  SELECT p.res_id,
         COALESCE(fp.forced_id, p.res_id::text) AS pat_id
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
  SELECT pr.res_id,
         COALESCE(fpr.forced_id, pr.res_id::text) AS prac_id
  FROM   hfj_resource pr
  LEFT JOIN hfj_forced_id fpr ON fpr.resource_pid = pr.res_id
  WHERE  pr.res_type = 'Practitioner' AND pr.res_deleted_at IS NULL
),
enc_date AS (
  SELECT d.res_id AS enc_res_id,
         d.sp_value_high AS period_end,
         d.sp_value_low  AS period_start
  FROM   hfj_spidx_date d
  JOIN   hfj_resource r ON r.res_id = d.res_id
  WHERE  r.res_type = 'Encounter' AND d.sp_name = 'date'
)
SELECT
  'Patient/'   || pat.pat_id AS patientId,
  'Encounter/' || enc.enc_id AS encounterId,
  CASE WHEN prac.prac_id IS NOT NULL
       THEN 'Practitioner/' || prac.prac_id
       ELSE NULL END        AS practitionerId,
  COALESCE(enc_date.period_end, enc_date.period_start, NOW()) AS authored,
  'Patient/' || pat.pat_id  AS src
FROM enc
JOIN enc_patient ON enc.res_id = enc_patient.enc_res_id
JOIN pat         ON pat.res_id = enc_patient.pat_res_id
LEFT JOIN enc_prac_one ep ON enc.res_id = ep.enc_res_id
LEFT JOIN prac          ON prac.res_id = ep.prac_res_id
LEFT JOIN enc_date      ON enc.res_id = enc_date.enc_res_id
ORDER BY patientId, encounterId;
"""

def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    conn = psycopg2.connect(
        host=DB_HOST, port=DB_PORT,
        dbname=DB_NAME, user=DB_USER, password=DB_PASS
    )
    cur = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
    cur.execute(SQL)
    rows = cur.fetchall()

    if not rows:
        print("No results found.")
        return

    headers = [desc.name for desc in cur.description]

    with OUT_FILE.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(headers)
        for row in rows:
            writer.writerow(row)

    print(f"Wrote {len(rows)} rows to {OUT_FILE}")

    cur.close()
    conn.close()


if __name__ == "__main__":
    main()
