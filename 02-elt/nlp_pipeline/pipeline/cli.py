# pipeline/cli.py
import os, uuid, logging
from time import perf_counter
from collections import Counter
from datetime import datetime, timezone
from argparse import ArgumentParser

from .utils import setup_logging, load_yaml, merge_env, parse_since
from .io import PgIO
from .preprocess import clean_text
from .pii import contains_pii
from .lang import detect_language
# from .sentiment import load_sentiment, score as score_sent
from .sentiment import load_sentiment, score_batch
from .themes import load_theme_config, load_zero_shot, pick_themes
from .toxicity import load_toxicity, score as score_tox

try:
    from tqdm import tqdm
except Exception:  # tqdm is optional; continue quietly if unavailable
    def tqdm(x, **kwargs):  # type: ignore
        return x

def main():
    # ── args ────────────────────────────────────────────────────────────────────
    parser = ArgumentParser(prog="prem-nlp")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_score = sub.add_parser("score", help="Score new free-text answers")
    p_score.add_argument("--config", default="config.yaml")
    p_score.add_argument("--themes", default="themes.yml")
    p_score.add_argument("--since", default=None, help="Override window (e.g., 7d, 24h, 2024-01-01)")
    p_score.add_argument("--limit", type=int, default=None, help="Override batch limit")
    p_score.add_argument("--model-name", default=None, help="Override model_name for this run")
    p_score.add_argument("--dry-run", action="store_true", help="Do not write predictions")
    p_score.add_argument("--verbose", action="store_true", help="Debug logging")
    args = parser.parse_args()

    setup_logging(level=logging.DEBUG if getattr(args, "verbose", False) else logging.INFO)
    log = logging.getLogger("prem-nlp")

    if args.cmd != "score":
        parser.error("Only 'score' is supported currently")

    # ── config/env ──────────────────────────────────────────────────────────────
    t0 = perf_counter()
    cfg = load_yaml(args.config)
    db_cfg, hf_cfg = merge_env(cfg["db"], cfg.get("hf", {}))
    scoring_cfg = cfg["scoring"]
    model_cfg = cfg["models"]

    if args.limit is not None:
        scoring_cfg["batch_limit"] = int(args.limit)
    if args.model_name:
        scoring_cfg["model_name"] = args.model_name

    since_str = args.since if args.since is not None else scoring_cfg.get("since")
    since_dt = parse_since(since_str)

    # Hugging Face cache/token
    if hf_cfg.get("cache_dir"):
        os.makedirs(hf_cfg["cache_dir"], exist_ok=True)
        os.environ["HF_HOME"] = hf_cfg["cache_dir"]
    if hf_cfg.get("token"):
        os.environ["HUGGINGFACE_HUB_TOKEN"] = hf_cfg["token"]

    log.info(
        "Startup | DB host=%s db=%s schema=%s | model_name=%s | since=%s (UTC=%s) | limit=%s | HF cache=%s token=%s",
        db_cfg.get("host"),
        db_cfg.get("database"),
        db_cfg.get("schema"),
        scoring_cfg["model_name"],
        since_str,
        since_dt,
        scoring_cfg.get("batch_limit"),
        hf_cfg.get("cache_dir"),
        "set" if bool(hf_cfg.get("token")) else "not-set",
    )

    # ── DB conn ────────────────────────────────────────────────────────────────
    io = PgIO(db_cfg)

    try:
        # ── model loading ──────────────────────────────────────────────────────
        t_load = perf_counter()
        log.info("Loading sentiment model: %s", model_cfg["sentiment"])
        sent_pipe = load_sentiment(model_cfg["sentiment"])
        log.debug("Sentiment model loaded in %.2fs", perf_counter() - t_load)

        zsc_pipe = None
        if model_cfg.get("enable_zero_shot", True):
            t_z = perf_counter()
            log.info("Loading zero-shot model: %s", model_cfg["zero_shot"])
            zsc_pipe = load_zero_shot(model_cfg["zero_shot"])
            log.debug("Zero-shot model loaded in %.2fs", perf_counter() - t_z)

        tox_pipe = load_toxicity(model_cfg.get("toxicity") or None)

        # ── themes config ──────────────────────────────────────────────────────
        themes_yaml = load_yaml(args.themes)
        labels, keywords = load_theme_config(themes_yaml)
        log.info("Theme labels=%s (keywords=%s)", labels, {k: len(v) for k, v in keywords.items()})

        # ── fetch batch ───────────────────────────────────────────────────────
        rows = io.fetch_pending(
            model_name=scoring_cfg["model_name"],
            limit=scoring_cfg["batch_limit"],
            since_utc=since_dt,
        )
        n = len(rows)
        if n == 0:
            log.info("Fetched 0 pending rows. Nothing to do.")
            return

        authored = [r[2] for r in rows]
        log.info("Fetched %d rows | authored_ts range: %s .. %s", n, min(authored), max(authored))
        
        # ── score (batched) ───────────────────────────────────────────────────────────
        run_id = str(uuid.uuid4())
        to_upsert = []
        err = 0
        sent_counts = Counter()
        theme_counts = Counter()

        # 1) Pre-clean & collect
        texts = []
        metas = []   # (qr_id, item_linkid, authored_ts, cleaned)
        for (qr_id, item_linkid, authored_ts, text_raw, org_id, clinician_id) in rows:
            cleaned = clean_text(text_raw)
            if cleaned and len(cleaned) >= 3:
                metas.append((qr_id, item_linkid, authored_ts, cleaned))
                texts.append(cleaned)

        if not texts:
            log.info("Nothing to score after cleaning.")
            return

        # 2) Sentiment in one go (batch)
        sent_results = score_batch(sent_pipe, texts)  # list[(label, score)]

        # 3) Themes – fast rule-first (no zero-shot), or enable selective ZSC later
        #    If you want full ZSC batching, you can add it here with batch_size=8–16.
        override = float(scoring_cfg.get("rule_override_max_zsc", 0.80))

        for i, (qr_id, item_linkid, authored_ts, cleaned) in enumerate(tqdm(metas, desc="Scoring", unit="text")):
            try:
                s_label, s_score = sent_results[i]

                # rules-first pass
                themes, scored = pick_themes(
                    text=cleaned,
                    labels=labels,
                    zsc_pipe=None,                 # rules only
                    keywords=keywords,
                    conf_min=scoring_cfg.get("theme_confidence_min", 0.40),
                )

                # selective ZSC only when rules found nothing (or keep a low-confidence heuristic)
                if not themes and zsc_pipe:
                    themes, scored = pick_themes(
                        text=cleaned,
                        labels=labels,
                        zsc_pipe=zsc_pipe,         # enable ZSC just for this text
                        keywords=keywords,
                        conf_min=scoring_cfg.get("theme_confidence_min", 0.40),
                    )

                # optional: override if ZSC top-1 is very confident
                override = float(scoring_cfg.get("rule_override_max_zsc", 0.80))
                if scored:
                    top_lab, top_score = scored[0]
                    if top_lab and float(top_score) >= override:
                        if top_lab in themes:
                            try:
                                themes.remove(top_lab)
                            except ValueError:
                                pass
                        themes.insert(0, top_lab)

                t_primary = themes[0] if themes else None
                t_secondary = themes[1] if len(themes) > 1 else None

                # Toxicity (per-row; tiny cost). 
                #_tox = score_tox(tox_pipe, cleaned)

                sent_counts[s_label] += 1
                if t_primary:
                    theme_counts[t_primary] += 1

                created_at = datetime.now(timezone.utc)
                to_upsert.append(
                    (
                        run_id,
                        scoring_cfg["model_name"],
                        qr_id,
                        item_linkid,
                        authored_ts,
                        s_label,
                        s_score,
                        t_primary,
                        t_secondary,
                        created_at,
                    )
                )
            except Exception as e:
                err += 1
                logging.getLogger("prem-nlp").exception(
                    "Error scoring qr_id=%s item=%s: %s", qr_id, item_linkid, e
                )

        log.info(
            "Scored %d rows (errors=%d) | sentiment=%s",
            len(to_upsert),
            err,
            dict(sent_counts),
        )
        log.info("Top themes: %s", theme_counts.most_common(10))

        if args.dry_run:
            log.info("--dry-run: skipping upsert. Example row: %s", to_upsert[:1])
            return

        # ── upsert ────────────────────────────────────────────────────────────
        t_up = perf_counter()
        io.upsert_predictions(to_upsert)
        log.info("Upserted %d predictions in %.2fs", len(to_upsert), perf_counter() - t_up)

    finally:
        io.close()
        log.debug("Total runtime %.2fs", perf_counter() - t0)

if __name__ == "__main__":
    main()
