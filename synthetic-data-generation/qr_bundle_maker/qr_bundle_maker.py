#!/usr/bin/env python3
"""
qr_bundle_maker.py

Unified tool to synthesize FHIR Bundle of QuestionnaireResponse resources
from a single header CSV, for either:
  - NREQ (17-item Likert 1..3 auto-generated)
  - PPNQ (open-ended PREM + NPS with dry-run text generation)

Design goals: DRY, simple CLI, deterministic RNG (seedable), minimal deps.
No network calls by default. Outputs NDJSON or JSON bundles (FHIR batch).

Usage examples:
  # NREQ (Likert only, deterministic with seed)
  python qr_bundle_maker.py --mode nreq --csv QuestionnaireResponse-Header.csv --out output --seed 42

  # PPNQ (dry-run open text + random NPS)
  python qr_bundle_maker.py --mode ppnq --csv QuestionnaireResponse-Header.csv --out output --dry-run --seed 7

  # Override chunk size (files capped at N resources each)
  python qr_bundle_maker.py --mode nreq --csv QuestionnaireResponse-Header.csv --out output --chunk-size 250

  # Use a custom Questionnaire JSON
  python qr_bundle_maker.py --mode nreq --csv QuestionnaireResponse-Header.csv --out output \
      --questionnaire-file ./NREQ.json --questionnaire-url http://example.org/fhir/Questionnaire/NREQ

"""

from __future__ import annotations
import argparse
import csv
import json
import math
import random
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Any, Iterable, Optional, Tuple

# -----------------------------
# Utilities (CSV, time, refs)
# -----------------------------

def detect_delimiter(csv_path: Path) -> str:
    sample = csv_path.read_text(encoding="utf-8", errors="ignore")
    try:
        sniffer = csv.Sniffer()
        dialect = sniffer.sniff(sample.splitlines()[0] if sample else ",")
        return dialect.delimiter
    except Exception:
        # Fallback: try common delimiters
        for cand in [",", ";", "\t", "|"]:
            if cand in sample.splitlines()[0]:
                return cand
        return ","


def normalize_headers(row: Dict[str, Any]) -> Dict[str, Any]:
    """Return a dict with case-insensitive keys while preserving values."""
    return { (k or "").strip().lower(): v for k, v in row.items() }


def to_fhir_datetime(dt_str: Optional[str] = None) -> str:
    """Return an RFC3339 FHIR DateTime with offset; use now() if not provided."""
    if dt_str:
        # Attempt several common formats
        fmts = [
            "%Y-%m-%d",
            "%Y-%m-%d %H:%M",
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%dT%H:%M",
            "%Y-%m-%dT%H:%M:%S",
            "%Y-%m-%dT%H:%M:%S%z",
            "%Y-%m-%d %H:%M:%S%z",
        ]
        for f in fmts:
            try:
                if "%z" in f:
                    dt = datetime.strptime(dt_str, f)
                else:
                    dt = datetime.strptime(dt_str, f).replace(tzinfo=timezone.utc)
                return dt.isoformat()
            except Exception:
                pass
    # Fallback: now with local offset if available
    now = datetime.now().astimezone()
    return now.isoformat(timespec="seconds")


def rel_ref(resource_type: str, identifier: str) -> str:
    """Return 'Type/id' if identifier isn't already a reference string."""
    if not identifier:
        return ""
    s = str(identifier).strip()
    if "/" in s or s.startswith("urn:uuid:") or s.startswith("http"):
        return s
    return f"{resource_type}/{s}"


# -----------------------------
# Built-in Questionnaires
# -----------------------------

BUILTIN_NREQ = {
  "resourceType": "Questionnaire",
  "url": "http://example.org/fhir/Questionnaire/NREQ",
  "version": "1.0",
  "name": "NREQ",
  "title": "Neurorehabilitation Experience Questionnaire (NREQ)",
  "status": "active",
  "item": [
    {"linkId": f"nreq-q{i}", "type": "choice"} for i in range(1, 18)
  ]
}

# Displays/Codes for Likert 1..3 (NREQ)
NREQ_LIKERT_SYSTEM = "http://example.org/fhir/CodeSystem/nreq-likert-3"
NREQ_LIKERT_CODE = {1: "disagree", 2: "neutral", 3: "agree"}
NREQ_LIKERT_DISPLAY = {1: "Mostly disagree", 2: "Not sure", 3: "Mostly agree"}

BUILTIN_PPNQ = {
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

# -----------------------------
# Header CSV schema
# -----------------------------

# We accept multiple aliases for the same concept to be flexible.
HEADER_ALIASES = {
    "patient": ["patient", "patientid", "patient_id", "subject", "subjectid"],
    "encounter": ["encounter", "encounterid", "encounter_id"],
    "author": ["author", "authorid", "author_id", "practitioner", "practitionerid"],
    "source": ["source", "sourceid", "source_id"],
    "authored": ["authored", "authoredon", "date"],
    "qr_id": ["qr_id", "questionnaireresponseid", "qrid"],
}

def pick_ci(row_ci: Dict[str, Any], keys: List[str], default: str = "") -> str:
    for k in keys:
        if k in row_ci and str(row_ci[k]).strip():
            return str(row_ci[k]).strip()
    return default


# -----------------------------
# Answer strategies
# -----------------------------

def gen_nreq_answers(
    questionnaire: Dict[str, Any],
    rng: random.Random,
    likert_probs: Tuple[float, float, float] = (1/3, 1/3, 1/3),
) -> List[Dict[str, Any]]:
    items = [it for it in questionnaire.get("item", []) if it.get("linkId", "").startswith("nreq-q")]
    answers = []
    for it in items:
        r = rng.random()
        if r < likert_probs[0]:
            v = 1
        elif r < likert_probs[0] + likert_probs[1]:
            v = 2
        else:
            v = 3
        answers.append({
            "linkId": it["linkId"],
            "valueCoding": {
                "system": NREQ_LIKERT_SYSTEM,
                "code": NREQ_LIKERT_CODE[v],
                "display": NREQ_LIKERT_DISPLAY[v],
            }
        })
    return answers


NPS_SYSTEM = "http://example.org/fhir/CodeSystem/nps-scale"

def _dummy_sentence(topic: str, rng: random.Random) -> str:
    stems = [
        "Overall, I felt that",
        "From my perspective,",
        "In general,",
        "My experience was that",
        "I noticed that",
        "It seemed to me that",
    ]
    phrases = [
        " the team communicated clearly",
        " the care was well coordinated",
        " I was listened to and involved",
        " safety was taken seriously",
        " my goals were understood",
        " follow-up plans were consistent",
        " access was straightforward",
    ]
    return f"{rng.choice(stems)}{rng.choice(phrases)} regarding {topic}."


def gen_ppnq_answers_dry(questionnaire: Dict[str, Any], rng: random.Random) -> List[Dict[str, Any]]:
    topics = {
        "ppnq-q1": "access to services",
        "ppnq-q2": "meeting my needs",
        "ppnq-q3a": "seeing the same clinicians",
        "ppnq-q3b": "information sharing across professionals",
        "ppnq-q4": "coordination between specialists",
        "ppnq-q5": "feeling safe during therapies",
        "ppnq-q6": "listening to my preferences",
        "ppnq-q7": "self-management support",
        "ppnq-q8": "trust in the team",
    }
    answers = []
    # Free-text responses
    for linkId, topic in topics.items():
        answers.append({"linkId": linkId, "valueString": _dummy_sentence(topic, rng)})
    # NPS 0..10
    nps = rng.randint(0, 10)
    answers.append({
        "linkId": "ppnq-q9",
        "valueCoding": {"system": NPS_SYSTEM, "code": str(nps), "display": str(nps)}
    })
    reason = "Excellent teamwork and clear goals." if nps >= 9 else (
             "Good care overall but some waits." if nps >= 7 else
             "Several issues affected my experience.")
    answers.append({"linkId": "ppnq-q9-text", "valueString": reason})
    return answers


# -----------------------------
# QR + Bundle builders
# -----------------------------

def build_qr(
    mode: str,
    row_ci: Dict[str, Any],
    questionnaire: Dict[str, Any],
    questionnaire_url: Optional[str],
    answers: List[Dict[str, Any]]
) -> Dict[str, Any]:
    patient_id = pick_ci(row_ci, HEADER_ALIASES["patient"])
    encounter_id = pick_ci(row_ci, HEADER_ALIASES["encounter"])
    author_id = pick_ci(row_ci, HEADER_ALIASES["author"])
    source_id = pick_ci(row_ci, HEADER_ALIASES["source"]) or patient_id
    authored_str = pick_ci(row_ci, HEADER_ALIASES["authored"])
    authored = to_fhir_datetime(authored_str)
    qr_id = pick_ci(row_ci, HEADER_ALIASES["qr_id"]) or str(uuid.uuid4())

    # Build minimal narrative with quick glance of answers
    def narrative_line(a: Dict[str, Any]) -> str:
        if "valueCoding" in a:
            display = a["valueCoding"].get("display") or a["valueCoding"].get("code")
            return f"{a['linkId']}: {display}"
        else:
            s = a.get("valueString", "")[:80]
            return f"{a['linkId']}: {s}"
    narrative = "<br/>".join(narrative_line(a) for a in answers)

    qr = {
        "resourceType": "QuestionnaireResponse",
        "id": qr_id,
        "status": "completed",
        "questionnaire": questionnaire_url or questionnaire.get("url"),
        "subject": {"reference": rel_ref("Patient", patient_id)} if patient_id else None,
        "encounter": {"reference": rel_ref("Encounter", encounter_id)} if encounter_id else None,
        "author": {"reference": rel_ref("Practitioner", author_id)} if author_id else None,
        "source": {"reference": rel_ref("Patient", source_id)} if source_id else None,
        "authored": authored,
        "text": {
            "status": "generated",
            "div": f"<div xmlns='http://www.w3.org/1999/xhtml'><p><b>{mode.upper()} QR</b></p><p>{narrative}</p></div>"
        },
        "item": []
    }

    # Group answers under items with matching linkId
    by_link: Dict[str, List[Dict[str, Any]]] = {}
    for a in answers:
        by_link.setdefault(a["linkId"], []).append({k: v for k, v in a.items() if k != "linkId"})

    for it in questionnaire.get("item", []):
        lid = it.get("linkId")
        if lid in by_link:
            qr["item"].append({"linkId": lid, "answer": by_link[lid]})
    # Remove None keys
    qr = {k: v for k, v in qr.items() if v is not None}
    return qr


def make_entry(resource: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "fullUrl": f"urn:uuid:{uuid.uuid4()}",
        "resource": resource,
        "request": {"method": "POST", "url": resource["resourceType"]}
    }


def write_bundles(resources: List[Dict[str, Any]], out_dir: Path, prefix: str, chunk_size: int = 250) -> List[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    chunks = math.ceil(len(resources) / max(1, chunk_size))
    for i in range(chunks):
        batch = resources[i*chunk_size:(i+1)*chunk_size]
        bundle = {
            "resourceType": "Bundle",
            "type": "batch",
            "entry": [make_entry(r) for r in batch]
        }
        p = out_dir / f"{prefix}_batch_bundle_{i+1:03d}.json"
        p.write_text(json.dumps(bundle, indent=2), encoding="utf-8")
        paths.append(p)
    return paths


# -----------------------------
# Header ingestion
# -----------------------------

def read_header_csv(path: Path) -> List[Dict[str, Any]]:
    delim = detect_delimiter(path)
    rows: List[Dict[str, Any]] = []
    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f, delimiter=delim)
        for row in reader:
            rows.append(normalize_headers(row))
    return rows



# -----------------------------
# .env configuration
# -----------------------------

@dataclass
class LLMConfig:
    api_key: Optional[str]
    model: str = "gpt-4o-mini"
    temperature: float = 0.6
    max_retries: int = 3

def load_dotenv(path: Path) -> Dict[str, str]:
    """Tiny .env loader: lines like KEY=VALUE; ignores blanks and # comments."""
    env = {}
    if not path.exists():
        return env
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env

def get_llm_config() -> LLMConfig:
    # precedence: actual environment then .env file; we read os.environ at call time
    import os
    env_file = Path(".env")
    file_env = load_dotenv(env_file)
    api_key = os.getenv("OPENAI_API_KEY") or file_env.get("OPENAI_API_KEY")
    model = os.getenv("LLM_MODEL") or file_env.get("LLM_MODEL") or "gpt-4o-mini"
    try:
        temperature = float(os.getenv("LLM_TEMPERATURE") or file_env.get("LLM_TEMPERATURE") or 0.6)
    except Exception:
        temperature = 0.6
    try:
        max_retries = int(os.getenv("LLM_MAX_RETRIES") or file_env.get("LLM_MAX_RETRIES") or 3)
    except Exception:
        max_retries = 3
    return LLMConfig(api_key=api_key, model=model, temperature=temperature, max_retries=max_retries)
# -----------------------------
# LLM generation for PPNQ
# -----------------------------

def _ppnq_schema_prompt(questionnaire: Dict[str, Any]) -> str:
    """Return an instruction block describing the exact JSON schema required."""
    required_ids = [it["linkId"] for it in questionnaire.get("item", [])]
    # Provide basic item descriptions if present
    lines = [
        "You write realistic, succinct patient feedback for a neurorehabilitation PREM.",
        "Return a SINGLE JSON object with this shape:",
        "{",
        '  "answers": [',
        '    {"linkId": "<id>", "valueString": "<short paragraph>"},',
        '    ...',
        '    {"linkId": "ppnq-q9", "valueCoding": {"system": "http://example.org/fhir/CodeSystem/nps-0-10", "code": "<0-10 string>", "display": "<same as code>"}},',
        '    {"linkId": "ppnq-q9-text", "valueString": "<one-sentence reason for the score>"}',
        "  ]",
        "}",
        "",
        "Rules:",
        "- Include EVERY required linkId exactly once: " + ", ".join(required_ids),
        "- Keep responses specific, first-person, and plausible. Avoid PHI; no names, dates, phone numbers.",
        "- For ppnq-q1..q8: one concise sentence each (max ~25 words).",
        "- For ppnq-q9: choose an integer 0..10 that matches the sentiment you wrote; encode as valueCoding (system/code/display).",
        "- For ppnq-q9-text: one short reason consistent with the score.",
        "- Output ONLY the JSON. No markdown fences, no comments.",
    ]
    return "\n".join(lines)


def _ppnq_user_context(row_ci: Dict[str, Any]) -> str:
    pid = pick_ci(row_ci, HEADER_ALIASES["patient"]) or "unknown"
    eid = pick_ci(row_ci, HEADER_ALIASES["encounter"]) or "unknown"
    authored = to_fhir_datetime(pick_ci(row_ci, HEADER_ALIASES["authored"]))
    return f"Patient={pid} Encounter={eid} Authored={authored}"


def _call_openai_json(prompt: str, cfg: LLMConfig) -> Dict[str, Any]:
    """Call OpenAI Chat Completions with JSON output. Requires OPENAI_API_KEY."""
    # Prefer the official client, fallback to requests
    try:
        from openai import OpenAI
        client = OpenAI()
        # Newer SDK supports response_format={"type":"json_object"}
        resp = client.chat.completions.create(
            model=cfg.model,
            messages=[
                {"role": "system", "content": "You are a careful medical scribe that follows JSON schemas exactly."},
                {"role": "user", "content": prompt},
            ],
            temperature=cfg.temperature,
            response_format={"type": "json_object"},
        )
        content = resp.choices[0].message.content
        return json.loads(content)
    except Exception as e:
        # Minimal fallback using raw REST if openai package not available
        import os, time, requests
        api_key = cfg.api_key or os.getenv("OPENAI_API_KEY")
        if not api_key:
            raise RuntimeError("OPENAI_API_KEY is not set and the OpenAI SDK is unavailable.") from e
        url = "https://api.openai.com/v1/chat/completions"
        headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
        payload = {
            "model": cfg.model,
            "messages": [
                {"role": "system", "content": "You are a careful medical scribe that follows JSON schemas exactly."},
                {"role": "user", "content": prompt},
            ],
            "temperature": cfg.temperature,
            "response_format": {"type": "json_object"},
        }
        for attempt in range(cfg.max_retries):
            r = requests.post(url, headers=headers, json=payload, timeout=60)
            if r.status_code == 200:
                try:
                    content = r.json()["choices"][0]["message"]["content"]
                    return json.loads(content)
                except Exception:
                    pass
            # basic backoff
            time.sleep(1.5 * (attempt + 1))
        raise RuntimeError(f"OpenAI REST call failed after {cfg.max_retries} attempts: {r.status_code} {r.text}")


def _validate_ppnq_answers(obj: Dict[str, Any]) -> List[Dict[str, Any]]:
    if not isinstance(obj, dict) or "answers" not in obj or not isinstance(obj["answers"], list):
        raise ValueError("LLM output must be a JSON object with an 'answers' array.")
    out = []
    seen = set()
    for a in obj["answers"]:
        if not isinstance(a, dict) or "linkId" not in a:
            continue
        linkId = a["linkId"]
        if linkId in seen:
            continue
        seen.add(linkId)
        if "valueString" in a and isinstance(a["valueString"], str):
            out.append({"linkId": linkId, "valueString": a["valueString"]})
        elif "valueCoding" in a and isinstance(a["valueCoding"], dict):
            vc = a["valueCoding"]
            sys_ = vc.get("system") or NPS_SYSTEM
            code = str(vc.get("code"))
            disp = str(vc.get("display") or code)
            out.append({"linkId": linkId, "valueCoding": {"system": sys_, "code": code, "display": disp}})
    # Ensure required set
    req = {"ppnq-q1","ppnq-q2","ppnq-q3a","ppnq-q3b","ppnq-q4","ppnq-q5","ppnq-q6","ppnq-q7","ppnq-q8","ppnq-q9","ppnq-q9-text"}
    got = {a["linkId"] for a in out}
    missing = sorted(req - got)
    if missing:
        raise ValueError("Missing required answers: " + ", ".join(missing))
    # Coerce NPS to be 0..10 if present
    for a in out:
        if a["linkId"] == "ppnq-q9" and "valueCoding" in a:
            try:
                nps = int(a["valueCoding"]["code"])
                nps = max(0, min(10, nps))
                a["valueCoding"]["code"] = str(nps)
                a["valueCoding"]["display"] = str(nps)
                a["valueCoding"]["system"] = NPS_SYSTEM
            except Exception:
                a["valueCoding"] = {"system": NPS_SYSTEM, "code": "7", "display": "7"}
    return out


def gen_ppnq_answers_llm(questionnaire: Dict[str, Any], row_ci: Dict[str, Any], cfg: LLMConfig) -> List[Dict[str, Any]]:
    prompt = _ppnq_schema_prompt(questionnaire) + "\n\n" + _ppnq_user_context(row_ci)
    last_err = None
    for _ in range(max(1, args.max_retries)):
        try:
            obj = _call_openai_json(prompt, cfg)
            return _validate_ppnq_answers(obj)
        except Exception as e:
            last_err = e
    raise last_err if last_err else RuntimeError("Unknown LLM error")

# -----------------------------
# Main flow
# -----------------------------

def parse_likert_dist(s: Optional[str]) -> Tuple[float, float, float]:
    if not s:
        return (1/3, 1/3, 1/3)
    parts = [float(x) for x in s.split(",")]
    if len(parts) != 3:
        raise ValueError("--likert-dist must be three comma-separated numbers e.g. 0.2,0.5,0.3")
    total = sum(parts)
    if total <= 0:
        raise ValueError("likert distribution must sum to > 0")
    return (parts[0]/total, parts[1]/total, parts[2]/total)


def load_questionnaire(args) -> Dict[str, Any]:
    if args.questionnaire_file:
        q = json.loads(Path(args.questionnaire_file).read_text(encoding="utf-8"))
    else:
        q = BUILTIN_NREQ if args.mode == "nreq" else BUILTIN_PPNQ
    # If a URL override is provided, apply it
    if args.questionnaire_url:
        q = dict(q)
        q["url"] = args.questionnaire_url
    return q


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Synthesize FHIR QuestionnaireResponse Bundles")
    p.add_argument("--mode", choices=["nreq", "ppnq"], required=True, help="Which questionnaire to synthesize")
    p.add_argument("--csv", required=True, help="Header CSV (patients/encounters/authors/authored...)")
    p.add_argument("--out", default="output", help="Output directory")
    p.add_argument("--chunk-size", type=int, default=250, help="Max QuestionnaireResponses per bundle file")
    p.add_argument("--questionnaire-file", help="Optional path to Questionnaire JSON to use")
    p.add_argument("--questionnaire-url", help="Override Questionnaire canonical URL in QR.questionnaire")
    p.add_argument("--seed", type=int, default=None, help="Seed for RNG (for reproducible bundles)")

    # NREQ-specific
    p.add_argument("--likert-dist", help="Comma-separated probs for 1,2,3 (e.g., 0.2,0.5,0.3)")

    # PPNQ behavior
    p.add_argument("--dry-run", action="store_true", help="Generate placeholder text answers for PPNQ")
    # placeholders for future LLM support
    p.add_argument("--llm", action="store_true", help="Use LLM to generate open text answers for PPNQ (reads .env)")

    args = p.parse_args(argv)

    rng = random.Random(args.seed)
    header_rows = read_header_csv(Path(args.csv))
    if not header_rows:
        print("No rows found in header CSV.", file=sys.stderr)
        return 2

    questionnaire = load_questionnaire(args)
    questionnaire_url = args.questionnaire_url or questionnaire.get("url")

    resources: List[Dict[str, Any]] = []
    prefix = args.mode

    if args.mode == "nreq":
        likert_probs = parse_likert_dist(args.likert_dist)
        for row_ci in header_rows:
            answers = gen_nreq_answers(questionnaire, rng, likert_probs)
            qr = build_qr("nreq", row_ci, questionnaire, questionnaire_url, answers)
            resources.append(qr)

    elif args.mode == "ppnq":
        cfg = get_llm_config()
        for row_ci in header_rows:
            if args.llm and not args.dry_run:
                answers = gen_ppnq_answers_llm(questionnaire, row_ci, cfg)
            else:
                answers = gen_ppnq_answers_dry(questionnaire, rng)
            qr = build_qr("ppnq", row_ci, questionnaire, questionnaire_url, answers)
            resources.append(qr)

    paths = write_bundles(resources, Path(args.out), prefix, args.chunk_size)

    print(f"Created {len(resources)} QuestionnaireResponses in {len(paths)} bundle file(s):")
    for pth in paths:
        print(f" - {pth}")
    print("\nExample POST using curl (change FHIR_BASE):")
    print("  FHIR_BASE='https://your-fhir-server.example/fhir'")
    print(f"  for f in {Path(args.out) / (prefix + '_batch_bundle_*.json')}; do")
    print("    curl -sfS -X POST \"$FHIR_BASE\" \\")
    print("      -H 'content-type: application/fhir+json' \\")
    print("      --data-binary @\"$f\" | jq '.type,.total,.issue // empty'")
    print("  done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
