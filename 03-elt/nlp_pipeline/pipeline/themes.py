from transformers import pipeline

def load_theme_config(themes_yaml: dict):
    labels = list(themes_yaml["labels"])
    keywords = {k: [w.lower() for w in v] for k, v in themes_yaml.get("keywords", {}).items()}
    return labels, keywords

def rule_hit(text_lower: str, keywords: dict) -> str | None:
    for theme, kws in keywords.items():
        for kw in kws:
            if kw in text_lower:
                return theme
    return None

def load_zero_shot(model_name: str):
    return pipeline("zero-shot-classification", model=model_name, multi_label=False, truncation=True)

def pick_theme(
    text: str,
    labels: list[str],
    zsc_pipe=None,
    keywords: dict | None = None,
    conf_min: float = 0.40,
    rule_override_max_zsc: float = 0.80,
) -> tuple[str, str | None]:
    """
    Returns (primary, secondary). Falls back to 'other' on low confidence.
    """
    txt_l = text.lower()
    t_rule = None
    if keywords:
        t_rule = rule_hit(txt_l, keywords)

    if zsc_pipe:
        z = zsc_pipe(text, labels)
        top_label = z["labels"][0]
        top_score = float(z["scores"][0])
        second = z["labels"][1] if len(z["labels"]) > 1 else None

        # prefer rules if zsc not super confident
        primary = top_label
        secondary = second
        if t_rule and top_score < rule_override_max_zsc:
            primary = t_rule
            secondary = top_label if top_label != primary else second

        if top_score < conf_min:
            primary, secondary = "other", None
        if primary == secondary:
            secondary = None
        return primary, secondary

    # no zsc: rules only
    return t_rule or "other", None
