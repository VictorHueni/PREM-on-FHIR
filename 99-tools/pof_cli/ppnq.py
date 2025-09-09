
#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import time
import random
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
import requests
from utils import die, _vprint, _pick, _to_fhir_dt
from constants import HEADER_ALIASES



LLM_STATS = {
    "calls": 0,           # total HTTP POSTs made to the model
    "successes": 0,       # successful generations
    "retries": 0,         # retry POSTs after initial attempt
    "total_tokens": 0,    # summed when OpenAI returns usage (optional)
}


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



def build_ppnq_prompt(
    questionnaire: Dict[str, Any],
    nps_score: int,
    nps_bucket: str,
    style_seed: int,
    keyword_plan: Dict[str, List[str]],
) -> str:
    """
    Construct the user message that:
      - tells the LLM to produce ONLY q1..q8 + q9-text,
      - enforces coherence with a GIVEN NPS score/bucket,
      - asks for concise, natural, single-sentence outputs,
      - optionally suggests 0–2 keywords per item to include only if natural.
    """
    req_ids = [it["linkId"] for it in questionnaire.get("item", [])]
    # we only ask for these linkIds from the LLM
    llm_ids = [lid for lid in req_ids if lid in {
        "ppnq-q1","ppnq-q2","ppnq-q3a","ppnq-q3b","ppnq-q4","ppnq-q5","ppnq-q6","ppnq-q7","ppnq-q8","ppnq-q9-text"
    }]

    # a small style palette seeded deterministically
    rng = random.Random(style_seed)
    bucket_styles = {
        "detractor": ["frustrated","disappointed","worried","unsatisfied","concerned"],
        "passive":   ["mostly satisfied","okay","fine overall","could be better","mixed"],
        "promoter":  ["grateful","relieved","impressed","confident","reassured"],
    }
    style_hint = rng.choice(bucket_styles.get(nps_bucket, ["neutral"]))

    # per-item domain descriptors (kept short)
    domain_hints = {
        "ppnq-q1":"access",
        "ppnq-q2":"meeting needs",
        "ppnq-q3a":"continuity",
        "ppnq-q3b":"information sharing",
        "ppnq-q4":"coordination",
        "ppnq-q5":"safety",
        "ppnq-q6":"preferences",
        "ppnq-q7":"self-management support",
        "ppnq-q8":"trust",
        "ppnq-q9-text":"reason for NPS",
    }

    # keyword suggestions block
    kw_lines = []
    for lid in llm_ids:
        kws = keyword_plan.get(lid, [])
        if kws:
            kw_lines.append(f'  - {lid}: optional_keywords = {kws}')
    kw_block = "\n".join(kw_lines) if kw_lines else "  (no keyword suggestions)"

    # build the full instructions
    lines = [
        "You write realistic, succinct patient feedback for a neurorehabilitation PREM.",
        "Return a SINGLE JSON object with this shape:",
        "{",
        '  "answers": [',
        '    {"linkId": "<id>", "valueString": "<one concise sentence>"}',
        "  ]",
        "}",
        "",
        f"NPS (given): {nps_score}  |  bucket: {nps_bucket}",
        "Your sentences MUST be coherent with this overall experience:",
        "- detractor (0–6): clearly negative or mixed negatives; mention issues briefly.",
        "- passive (7–8): overall positive with a minor critique.",
        "- promoter (9–10): clearly positive; highlight strengths.",
        "",
        "Write one concise, natural sentence (~8–22 words) for each of the following linkIds:",
    ]
    for lid in llm_ids:
        lines.append(f"- {lid}  ({domain_hints.get(lid,'')})")
    lines += [
        "",
        f"Style hint (use sparingly): {style_hint}. Avoid repeating the same phrasing.",
        "If optional keywords are provided for an item, include at most one only if it fits naturally.",
        "Use everyday language; avoid clinical jargon or identifiers.",
        "",
        "Optional keyword suggestions:",
        kw_block,
        "",
        "Output rules:",
        "- Output ONLY the JSON (no markdown).",
        '- Use only "valueString" (do NOT include ppnq-q9; that score is already given).',
    ]
    return "\n".join(lines)

def _ppnq_user_context(row: Dict[str,Any]) -> str:
    pid = _pick(row, HEADER_ALIASES["patient"]) or "unknown"
    eid = _pick(row, HEADER_ALIASES["encounter"]) or "unknown"
    authored = _to_fhir_dt(_pick(row, HEADER_ALIASES["authored"]))
    return f"Patient={pid} Encounter={eid} Authored={authored}"

def _validate_ppnq_answers(obj: Dict[str, Any]) -> List[Dict[str, Any]]:
    if not isinstance(obj, dict) or "answers" not in obj or not isinstance(obj["answers"], list):
        die("LLM output must be a JSON object with an 'answers' array.", 2)
    out: List[Dict[str, Any]] = []
    seen = set()
    # The LLM no longer provides ppnq-q9 (score). We still require all others including ppnq-q9-text.
    required = {"ppnq-q1","ppnq-q2","ppnq-q3a","ppnq-q3b","ppnq-q4","ppnq-q5","ppnq-q6","ppnq-q7","ppnq-q8","ppnq-q9-text"}
    for a in obj["answers"]:
        if not isinstance(a, dict) or "linkId" not in a:
            continue
        lid = a["linkId"]
        if lid in seen:
            continue
        seen.add(lid)
        if "valueString" in a and isinstance(a["valueString"], str):
            # Keep the sentence as-is (downstream will trim if needed)
            out.append({"linkId": lid, "valueString": a["valueString"]})
        # silently ignore valueCoding entries; q9 is now inserted by the script
    missing = sorted(required - {a["linkId"] for a in out})
    if missing:
        die(f"LLM output missing required linkIds: {', '.join(missing)}", 2)
    # enforce we DO NOT get a ppnq-q9 coding from the model
    out = [a for a in out if a["linkId"] != "ppnq-q9"]
    return out

def _ppnq_answers_llm(
    questionnaire: Dict[str,Any],
    row: Dict[str,Any],
    model: str,
    temperature: float,
    max_retries: int,
    verbose: bool = False,
    row_index: Optional[int] = None,
    total_rows: Optional[int] = None,
    nps_dist_arg: Optional[str] = None,
    keyword_rate: float = 0.35,
    style_variance: float = 0.7,
) -> List[Dict[str,Any]]:
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        die("OPENAI_API_KEY is required when using --llm. Put it in your .env.", 2)
    url = "https://api.openai.com/v1/chat/completions"
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}

    # 1) Deterministic NPS (script-side)
    # seed: prefer authored timestamp + row idx for variability if present
    rng_seed_basis = f"{_ppnq_user_context(row)}::{row_index or 0}"
    rng = random.Random()
    rng.seed(rng_seed_basis)
    dist = _parse_nps_dist_arg(nps_dist_arg)
    nps_score, nps_bucket = gen_nps(rng, dist)
    # style seed derived from a second draw modulated by style_variance
    style_seed = (int(rng.random() * 10_000_000) ^ int(style_variance * 1_000_000)) & 0x7FFFFFFF

    # 2) Keyword plan (optional; best-effort)
    kw_plan = _keyword_plan_for_ppnq(rng, keyword_rate=keyword_rate)

    # 3) Build prompt explicitly conditioning on NPS
    prompt = build_ppnq_prompt(
        questionnaire=questionnaire,
        nps_score=nps_score,
        nps_bucket=nps_bucket,
        style_seed=style_seed,
        keyword_plan=kw_plan,
    )
    prompt += "\n\n" + _ppnq_user_context(row)

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
    attempts = max(1, int(max_retries))
    for attempt in range(attempts):
        try:
            LLM_STATS["calls"] += 1
            t0 = time.perf_counter()
            r = requests.post(url, headers=headers, data=json.dumps(payload), timeout=60)
            dt = time.perf_counter() - t0
            if r.status_code == 200:
                data = r.json()
                content = data["choices"][0]["message"]["content"]
                try:
                    obj = json.loads(content)
                except json.JSONDecodeError:
                    raise RuntimeError("LLM returned non-JSON when JSON was requested.")
                ans = _validate_ppnq_answers(obj)

                # Insert deterministic ppnq-q9 (coding) generated by the script
                ans.append({
                    "linkId": "ppnq-q9",
                    "valueCoding": {
                        "system": NPS_SYSTEM,
                        "code": str(nps_score),
                        "display": str(nps_score),
                    }
                })

                # token accounting (best-effort)
                usage = data.get("usage") or {}
                tot = usage.get("total_tokens")
                if tot:
                    LLM_STATS["total_tokens"] += int(tot)
                LLM_STATS["successes"] += 1
                _vprint(verbose, f"   ✓ OK in {dt:.2f}s (tokens: {tot or 'n/a'})")
                return ans

            last = RuntimeError(f"OpenAI HTTP {r.status_code}: {r.text[:2000]}")
            _vprint(verbose, "   ✗ HTTP %s; %s" % (r.status_code, "retrying…" if attempt+1 < attempts else "giving up"))
        except Exception as e:
            last = e
            _vprint(verbose, f"   ✗ Error: {e.__class__.__name__}: {e}")

        time.sleep(1.5 * (attempt + 1))

    raise last or RuntimeError("LLM generation failed.")

def _ppnq_answers_dry(rng) -> List[Dict[str, Any]]:
    topics = {
        "ppnq-q1":"access to services", "ppnq-q2":"meeting my needs",
        "ppnq-q3a":"seeing the same clinicians", "ppnq-q3b":"information sharing",
        "ppnq-q4":"coordination", "ppnq-q5":"safety during therapies",
        "ppnq-q6":"listening to preferences", "ppnq-q7":"self-management support",
        "ppnq-q8":"trust in the team",
    }
    stems = ["Overall,","In general,","I felt","It seemed","From my perspective,"]
    traits = [
        " communication was clear"," care was coordinated"," access was reasonable"," the team listened",
        " safety was emphasised"," goals were understood"," support was practical"," I felt informed"
    ]
    answers = [{"linkId": lid, "valueString": f"{rng.choice(stems)}{rng.choice(traits)} about {topic}."}
               for lid,topic in topics.items()]

    # deterministic NPS with default skew
    nps, bucket = gen_nps(rng, None)
    answers.append({"linkId":"ppnq-q9","valueCoding":{"system":NPS_SYSTEM,"code":str(nps),"display":str(nps)}})

    # concise reason coherent with bucket
    if bucket == "promoter":
        reason = rng.choice([
            "Clear communication and coordinated care.",
            "Skilled team and smooth coordination.",
            "I felt supported and confident in the plan."
        ])
    elif bucket == "passive":
        reason = rng.choice([
            "Mostly positive, but access could be quicker.",
            "Good overall, with some delays.",
            "Helpful staff, though follow-up was uneven."
        ])
    else:
        reason = rng.choice([
            "Delays and poor coordination hurt my experience.",
            "I felt unheard and worried about safety.",
            "Information sharing was inconsistent."
        ])
    answers.append({"linkId":"ppnq-q9-text","valueString":reason})
    return answers
  
  
def gen_nps(rng: random.Random, dist: Optional[Dict[int, float]] = None) -> Tuple[int, str]:
    """
    Draw an NPS score in [0..10] with a configurable skew.
    Returns (score, bucket) where bucket ∈ {"detractor","passive","promoter"}.
    Default skew favors 8–10 while keeping full coverage.

    Default weights:
        0–6: 0.25 total (uniform within)
        7  : 0.15
        8  : 0.25
        9  : 0.20
        10 : 0.15
    """
    # default distribution
    if dist is None:
        dist = {i: 0.25/7 for i in range(0,7)}  # spread 0.25 over 0..6
        dist[7] = 0.15
        dist[8] = 0.25
        dist[9] = 0.20
        dist[10] = 0.15

    # sanitize + normalize
    keys = list(range(0,11))
    weights = [max(0.0, float(dist.get(k, 0.0))) for k in keys]
    total = sum(weights) or 1.0
    weights = [w/total for w in weights]

    # categorical sample deterministic via rng
    r = rng.random()
    acc = 0.0
    score = 0
    for k, w in zip(keys, weights):
        acc += w
        if r <= acc:
            score = k
            break

    bucket = "detractor" if score <= 6 else ("passive" if score <= 8 else "promoter")
    return score, bucket

def _parse_nps_dist_arg(s: Optional[str]) -> Optional[Dict[int, float]]:
    """
    Parse --nps-dist like "0:0.01,1:0.01,...,10:0.15" into a dict[int,float].
    Returns None if s is falsy.
    """
    if not s:
        return None
    out: Dict[int, float] = {}
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        if ":" not in part:
            die(f"Invalid --nps-dist item (missing ':'): {part}", 2)
        k, v = part.split(":", 1)
        try:
            i = int(k.strip())
            if i < 0 or i > 10:
                die(f"--nps-dist keys must be integers 0..10, got {i}", 2)
            out[i] = float(v.strip())
        except Exception:
            die(f"Invalid --nps-dist item: {part}", 2)
    if not out:
        die("Empty --nps-dist after parsing.", 2)
    return out

def _keyword_plan_for_ppnq(
    rng: random.Random,
    keyword_rate: float = 0.35,
    themes_yaml_path: Optional[Path] = None
) -> Dict[str, List[str]]:
    """
    Light-touch keyword planner to help downstream theme classification.
    Picks 0–2 optional keywords per item with probability 'keyword_rate'.
    If themes.yml is missing/unreadable, returns an empty plan.

    Returns a dict: { linkId -> [keyword?, keyword?] }
    """
    plan: Dict[str, List[str]] = {}
    try:
        import yaml
        if themes_yaml_path is None:
            themes_yaml_path = Path("themes.yml")
        if not themes_yaml_path.exists():
            # try repo structure used in your project
            alt = Path("01-data-generation/synthea/input/themes.yml")
            themes_yaml_path = alt if alt.exists() else themes_yaml_path
        if not themes_yaml_path.exists():
            return plan

        themes_yaml = yaml.safe_load(themes_yaml_path.read_text(encoding="utf-8"))
        # each domain → some typical anchors
        domain_keywords = {
            "ppnq-q1": ["waiting list","appointments","hotline","availability","access"],
            "ppnq-q2": ["needs","goals","fit","tailored","appropriate"],
            "ppnq-q3a":["continuity","same clinician","follow-up","relationship"],
            "ppnq-q3b":["handover","sharing","referrals","notes","information"],
            "ppnq-q4": ["coordination","team","plan","referral","integrated"],
            "ppnq-q5": ["safety","medication","risk","falls","checks"],
            "ppnq-q6": ["preferences","listened","values","choices","respect"],
            "ppnq-q7": ["self-management","education","home program","coaching","tools"],
            "ppnq-q8": ["trust","confidence","honesty","reassured","rapport"],
        }
        # we don’t enforce themes here—just optional hints
        for lid, kw_pool in domain_keywords.items():
            if rng.random() <= max(0.0, min(1.0, float(keyword_rate))):
                chosen = []
                if kw_pool:
                    chosen.append(rng.choice(kw_pool))
                if kw_pool and rng.random() < 0.25:  # very occasional 2nd word
                    # try a different keyword
                    alt = rng.choice(kw_pool)
                    if alt not in chosen:
                        chosen.append(alt)
                plan[lid] = chosen
    except Exception:
        # silent fallback; planner is optional
        return {}
    return plan

