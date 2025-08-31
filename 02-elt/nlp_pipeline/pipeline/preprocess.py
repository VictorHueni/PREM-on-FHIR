import re

URL_RE   = re.compile(r"https?://\S+|www\.\S+", re.IGNORECASE)
EMAIL_RE = re.compile(r"\b[\w\.-]+@[\w\.-]+\.\w{2,}\b")
WS_RE    = re.compile(r"\s+")

def clean_text(s: str) -> str:
    if s is None:
        return ""
    s = s.replace("\u200b", " ")
    s = URL_RE.sub(" <URL> ", s)
    s = EMAIL_RE.sub(" <EMAIL> ", s)
    s = WS_RE.sub(" ", s).strip()
    return s
