#!/usr/bin/env python3
from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple
from utils import die


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
