#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import uuid
from pathlib import Path
from typing import Any, Dict, List

from .constants import ALLOWED, ORDER
from .utils import die


# ---------------------------
# Command: bundle make-questionnaires
# (CodeSystem/ValueSet/Questionnaire → transaction Bundle)
# ---------------------------

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
