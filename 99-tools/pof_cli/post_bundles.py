#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path
from typing import Optional

import requests
from http import make_session
from utils import die, env_bool
from constants import DEFAULT_BASE

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

