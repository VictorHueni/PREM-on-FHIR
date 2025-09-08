from transformers import pipeline
from typing import List, Tuple, Set
import re


def load_theme_config(themes_yaml: dict):
    labels = list(themes_yaml["labels"])
    # precompile regex patterns for keywords with word boundaries
    compiled = {
        theme: [re.compile(rf"\b{re.escape(w.lower())}\b") for w in v]
        for theme, v in themes_yaml.get("keywords", {}).items()
    }
    return labels, compiled

def rule_hit(text_lower: str, compiled_keywords: dict) -> set[str]:
    hits = set()
    for theme, pats in compiled_keywords.items():
        if any(p.search(text_lower) for p in pats):
            hits.add(theme)
    return hits

def load_zero_shot(model_name: str):
    return pipeline(
        "zero-shot-classification",
        model=model_name,
        multi_label=True,           
        truncation=True,
        hypothesis_template="This patient comment is about {} in primary care."
    )


SENTIMENT_HINTS = re.compile(r"\b(excellent|great|good|amazing|poor|bad|terrible|awful|satisfied|unsatisfied|recommend)\b", re.I)

def pick_themes(
    text: str,
    labels: List[str],
    zsc_pipe=None,
    keywords: dict | None = None,
    conf_min: float = 0.35,          # a tad lower for recall
    conf_hi: float = 0.65,           # “confident” band
    max_labels: int = 3,
) -> Tuple[List[str], List[Tuple[str,float]]]:
    """
    Returns (themes, scored). Multi-label with rule floor and graceful fallbacks.
    """
    txt_l = text.casefold()
    rule_themes: Set[str] = rule_hit(txt_l, keywords) if keywords else set()

    scored = []
    if zsc_pipe:
        z = zsc_pipe(text, labels)
        scored = list(zip(z["labels"], map(float, z["scores"])))
        # ensure descending by score (HF already gives sorted, but be explicit)
        scored.sort(key=lambda x: x[1], reverse=True)

    # 1) take all ZSC labels >= conf_hi
    chosen = [lab for lab, s in scored if s >= conf_hi]

    # 2) add ZSC labels in [conf_min, conf_hi) until max_labels
    for lab, s in scored:
        if s >= conf_min and lab not in chosen and len(chosen) < max_labels:
            chosen.append(lab)

    # 3) union with rule themes (rules are conservative thanks to word boundaries)
    for lab in rule_themes:
        if lab not in chosen and len(chosen) < max_labels:
            chosen.append(lab)

    # 4) still empty? take ZSC top-1 if present
    if not chosen and scored:
        chosen = [scored[0][0]]

    # 5) still empty? sentiment → overall_experience; else other
    if not chosen:
        chosen = ["overall_experience"] if SENTIMENT_HINTS.search(text) else ["other"]

    # drop duplicates while preserving order
    seen = set(); chosen = [x for x in chosen if not (x in seen or seen.add(x))]

    return chosen, scored
