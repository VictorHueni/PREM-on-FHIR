from transformers import pipeline

""" def load_sentiment(model_name: str):
    return pipeline(
        "text-classification",
        model=model_name,
        return_all_scores=True,
        truncation=True,
        max_length=256
    )
"""

def load_sentiment(model_name: str, device: int | None = None):
    return pipeline(
        "text-classification",
        model=model_name,
        return_all_scores=True,
        truncation=True,
        max_length=256,
        device=device if device is not None else -1,   # -1 = CPU
    )

def score_batch(sent_pipe, texts: list[str]) -> list[tuple[str, float]]:
    outs = sent_pipe(texts, batch_size=32, truncation=True, max_length=256)
    results = []
    for out in outs:
        by = {d["label"]: d["score"] for d in out}
        neg = by.get("LABEL_0", by.get("negative", 0.0))
        neu = by.get("LABEL_1", by.get("neutral",  0.0))
        pos = by.get("LABEL_2", by.get("positive", 0.0))
        label = "positive" if pos >= max(neg, neu) else ("negative" if neg >= max(pos, neu) else "neutral")
        results.append((label, float(pos - neg)))
    return results

def score(sent_pipe, text: str) -> tuple[str, float]:
    """
    Returns (label, score in [-1,+1]).
    Supports both LABEL_X and string labels from the model.
    """
    """
    out = sent_pipe(text)[0]
    by_label = {d["label"]: d["score"] for d in out}
    neg = by_label.get("LABEL_0", by_label.get("negative", 0.0))
    neu = by_label.get("LABEL_1", by_label.get("neutral",  0.0))
    pos = by_label.get("LABEL_2", by_label.get("positive", 0.0))
    label = "positive" if pos >= max(neg, neu) else ("negative" if neg >= max(pos, neu) else "neutral")
    score = float(pos - neg)
    return label, score 
    """