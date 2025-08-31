# sanity-check.py
from pathlib import Path
from dotenv import load_dotenv
import os, psycopg2
from pipeline.utils import load_yaml, merge_env

# load .env next to this file
load_dotenv(dotenv_path=Path(__file__).with_name(".env"))

def need(var):
    v = os.getenv(var)
    if not v:
        raise SystemExit(f"Missing env var {var}. Check your .env or shell env.")
    return v

#contrl db connection
conn = psycopg2.connect(
    host=os.getenv("PG_HOST", "localhost"),
    port=int(os.getenv("PG_PORT", "5432")),
    dbname=need("PG_DB"),
    user=need("PG_USER"),
    password=need("PG_PASSWORD"),
)
with conn, conn.cursor() as cur:
    cur.execute("select count(*) from stg.nlp_prem_text;")
    print("stg.nlp_prem_text rows:", cur.fetchone()[0])



# env variables reads
cfg = load_yaml("config.yaml")
db_cfg, _ = merge_env(cfg["db"], cfg.get("hf", {}))
print(db_cfg)