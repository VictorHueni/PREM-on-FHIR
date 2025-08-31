# pipeline/utils.py
import os
import yaml
import logging
from datetime import datetime, timedelta, timezone

# NEW: load .env early
from dotenv import load_dotenv
from pathlib import Path

# try to load .env from CWD or project root (repo folder with config.yaml)
for base in [Path.cwd(), Path(__file__).resolve().parents[1]]:
    env = base / ".env"
    if env.exists():
        load_dotenv(env, override=False)  # don't override explicit shell vars
        break

LOG_FORMAT = "%(asctime)s | %(levelname)s | %(message)s"

def setup_logging(level=logging.INFO):
    logging.basicConfig(level=level, format=LOG_FORMAT)

def load_yaml(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)

def merge_env(db_cfg: dict, hf_cfg: dict):
    """Allow env vars to override YAML (handy in Docker/CI)."""
    out_db = dict(db_cfg)
    out_db["host"]     = os.getenv("PG_HOST", out_db.get("host"))
    out_db["port"]     = int(os.getenv("PG_PORT", out_db.get("port", 5432)))
    out_db["database"] = os.getenv("PG_DB",   out_db.get("database"))
    out_db["user"]     = os.getenv("PG_USER", out_db.get("user"))
    out_db["password"] = os.getenv("PG_PASSWORD", out_db.get("password", ""))
    out_db["schema"]   = os.getenv("PG_SCHEMA", out_db.get("schema", "stg"))

    out_hf = dict(hf_cfg or {})
    out_hf["cache_dir"] = os.getenv("HF_HOME", out_hf.get("cache_dir", ".hf_cache"))
    out_hf["token"]     = os.getenv("HUGGINGFACE_HUB_TOKEN", out_hf.get("token", ""))
    return out_db, out_hf

def parse_since(since: str) -> datetime | None:
    if not since:
        return None
    since = since.strip().lower()
    now = datetime.now(timezone.utc)
    if since.endswith("d") and since[:-1].isdigit():
        return now - timedelta(days=int(since[:-1]))
    if since.endswith("h") and since[:-1].isdigit():
        return now - timedelta(hours=int(since[:-1]))
    for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            dt = datetime.strptime(since, fmt)
            return dt.replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return None
