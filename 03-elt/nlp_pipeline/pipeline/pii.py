import re

EMAIL_RE = re.compile(r"\b[\w\.-]+@[\w\.-]+\.\w{2,}\b")
PHONE_RE = re.compile(r"\+?\d[\d\-\s]{6,}\d")
ID_RE    = re.compile(r"\b([A-Z]{2,3}\d{4,}|[A-Z]?\d{6,})\b")

def contains_pii(text: str) -> bool:
    if not text:
        return False
    return bool(EMAIL_RE.search(text) or PHONE_RE.search(text) or ID_RE.search(text))
