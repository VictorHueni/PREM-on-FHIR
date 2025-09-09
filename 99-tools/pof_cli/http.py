#!/usr/bin/env python3
from __future__ import annotations

import os
import requests

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
