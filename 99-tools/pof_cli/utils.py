#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, urlparse

from dotenv import load_dotenv

# ---------------------------
# .env loading
# ---------------------------
def _find_dotenv(start: Optional[str] = None) -> Optional[str]:
    """
    Search upward from start (or CWD) for a .env file.
    We cap at a few levels to avoid crawling the world.
    """
    d = Path(start or os.getcwd()).resolve()
    for _ in range(8):
        p = d / ".env"
        if p.is_file():
            return str(p)
        if d.parent == d:
            break
        d = d.parent
    return None

def load_env_from_root() -> None:
    """
    Load ENV values once, early.
    Priority: real env > .env values; we do not override existing OS env.
    """
    env_file = os.getenv("ENV_FILE") or _find_dotenv()
    if env_file and Path(env_file).is_file():
        load_dotenv(dotenv_path=env_file, override=False)


# ---------------------------
# small helpers
# ---------------------------

def env_bool(name: str, default: bool) -> bool:
    v = os.getenv(name)
    if v is None:
        return default
    return v.strip().lower() in ("1", "true", "yes", "y", "on")

def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")

def rel_ref(resource_type: str, identifier: str) -> str:
    if not identifier:
        return ""
    s = str(identifier).strip()
    if "/" in s or s.startswith("urn:uuid:") or s.startswith("http"):
        return s
    return f"{resource_type}/{s}"

def die(msg: str, code: int = 1) -> None:
    print(f"❌ {msg}", file=sys.stderr)
    raise SystemExit(code)

def _vprint(enabled: bool, *args, **kwargs) -> None:
    if enabled:
        print(*args, **kwargs)


