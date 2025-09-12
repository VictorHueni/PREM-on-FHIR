#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import time

import requests
from .http import make_session
from .utils import env_bool
from .constants import DEFAULT_BASE



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
