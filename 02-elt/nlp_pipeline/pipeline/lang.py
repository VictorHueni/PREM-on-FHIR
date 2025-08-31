import langid

def detect_language(text: str) -> str:
    if not text or len(text) < 3:
        return "und"
    lang, _ = langid.classify(text)
    return lang or "und"
