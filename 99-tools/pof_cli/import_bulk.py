#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import time
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, urlparse
import requests

from http import make_session
from utils import die, env_bool
from constants import DEFAULT_BASE


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

