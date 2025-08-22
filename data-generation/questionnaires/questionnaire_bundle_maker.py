#!/usr/bin/env python3
"""
make_tx_bundle.py

Read JSON files from an input folder and build a FHIR Bundle (type=transaction)
containing CodeSystem(s), ValueSet(s), and Questionnaire(s), created in the
right order: CodeSystem → ValueSet → Questionnaire.

Usage:
  python make_tx_bundle.py --in ./input --out ./output/questionnaire_bundle.json
Options:
  --method auto|put|post   : request method selection (default: auto)
                             - auto: PUT if resource has 'id', else POST
                             - put : always PUT (requires 'id')
                             - post: always POST
"""

from __future__ import annotations
import argparse
import json
import sys
import uuid
from pathlib import Path
from typing import Any, Dict, List

# resource order for dependency safety
ORDER = {
    "CodeSystem": 0,
    "ValueSet": 1,
    "Questionnaire": 2,
}

ALLOWED = set(ORDER.keys())


def load_json_files(indir: Path) -> List[Dict[str, Any]]:
    resources: List[Dict[str, Any]] = []
    for p in sorted(indir.glob("*.json")):
        try:
            obj = json.loads(p.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"Skipping {p.name}: not valid JSON ({e})", file=sys.stderr)
            continue

        # Single resource OR Bundle of entries? We only take individual resources
        if isinstance(obj, dict) and "resourceType" in obj:
            rt = obj["resourceType"]
            if rt in ALLOWED:
                resources.append(obj)
        else:
            print(f"Skipping {p.name}: not a single FHIR resource", file=sys.stderr)
    return resources


def sort_resources(resources: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    def key(r: Dict[str, Any]):
        return (ORDER.get(r.get("resourceType"), 99), r.get("id") or "")
    return sorted(resources, key=key)


def request_method(resource: Dict[str, Any], mode: str) -> str:
    if mode == "put":
        return "PUT"
    if mode == "post":
        return "POST"
    # auto
    return "PUT" if resource.get("id") else "POST"


def request_url(resource: Dict[str, Any]) -> str:
    rt = resource["resourceType"]
    rid = resource.get("id")
    return f"{rt}/{rid}" if rid else rt


def make_entry(resource: Dict[str, Any], mode: str) -> Dict[str, Any]:
    return {
        "fullUrl": f"urn:uuid:{uuid.uuid4()}",
        "resource": resource,
        "request": {
            "method": request_method(resource, mode),
            "url": request_url(resource),
        },
    }


def build_bundle(resources: List[Dict[str, Any]], mode: str) -> Dict[str, Any]:
    return {
        "resourceType": "Bundle",
        "type": "transaction",
        "entry": [make_entry(r, mode) for r in resources],
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Make FHIR transaction Bundle for CodeSystem/ValueSet/Questionnaire")
    ap.add_argument("--in", dest="indir", required=True, help="Input folder containing JSON resources")
    ap.add_argument("--out", dest="outfile", required=True, help="Output file for the transaction Bundle")
    ap.add_argument("--method", choices=["auto", "put", "post"], default="auto",
                    help="How to set Bundle.entry.request.method (default: auto)")
    args = ap.parse_args(argv)

    indir = Path(args.indir)
    out = Path(args.outfile)
    out.parent.mkdir(parents=True, exist_ok=True)

    resources = load_json_files(indir)
    if not resources:
        print(f"No CodeSystem/ValueSet/Questionnaire resources found in {indir}", file=sys.stderr)
        return 2

    resources = sort_resources(resources)
    bundle = build_bundle(resources, args.method)

    out.write_text(json.dumps(bundle, indent=2), encoding="utf-8")
    print(f"Wrote transaction Bundle with {len(resources)} resources → {out}")
    print("\nPOST it with:")
    print("  FHIR_BASE='http://localhost:8080/fhir' \\")
    print("  curl -sfS -X POST \"$FHIR_BASE\" -H 'content-type: application/fhir+json' --data-binary @\"%s\" | jq ." % out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
