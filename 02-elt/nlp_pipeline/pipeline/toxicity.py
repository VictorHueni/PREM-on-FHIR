from transformers import pipeline as hf_pipeline

def load_toxicity(model_name: str | None):
    if not model_name:
        return None
    return hf_pipeline("text-classification", model=model_name, truncation=True)

def score(tox_pipe, text: str, threshold: float = 0.5) -> bool | None:
    if not tox_pipe:
        return None
    res = tox_pipe(text)
    # each model differs; simplest: mark toxic if any label prob >= threshold and label contains 'toxic'
    for r in res:
        if ("toxic" in r.get("label", "").lower()) and float(r["score"]) >= threshold:
            return True
    return False
