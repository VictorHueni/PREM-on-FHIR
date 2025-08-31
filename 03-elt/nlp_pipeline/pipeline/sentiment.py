from transformers import pipeline

def load_sentiment(model_name: str):
    return pipeline(
        "text-classification",
        model=model_name,
        return_all_scores=True,
        truncation=True,
        max_length=256
    )

def score(sent_pipe, text: str) -> tuple[str, float]:
    """
    Returns (label, score in [-1,+1]).
    Supports both LABEL_X and string labels from the model.
    """
    out = sent_pipe(text)[0]
    by_label = {d["label"]: d["score"] for d in out}
    neg = by_label.get("LABEL_0", by_label.get("negative", 0.0))
    neu = by_label.get("LABEL_1", by_label.get("neutral",  0.0))
    pos = by_label.get("LABEL_2", by_label.get("positive", 0.0))
    label = "positive" if pos >= max(neg, neu) else ("negative" if neg >= max(pos, neu) else "neutral")
    score = float(pos - neg)
    return label, score
