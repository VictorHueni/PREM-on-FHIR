import logging
from typing import List, Tuple, Optional
from datetime import datetime
import psycopg2
from psycopg2.extras import execute_values

logger = logging.getLogger(__name__)

class PgIO:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.schema = cfg["schema"]
        self.conn = psycopg2.connect(
            host=cfg["host"], port=cfg["port"], dbname=cfg["database"],
            user=cfg["user"], password=cfg["password"]
        )
        self.ensure_unique_index()

    def close(self):
        self.conn.close()

    def ensure_unique_index(self):
        sql = f"""
        create unique index if not exists nlp_predictions_inbox_uk
          on {self.schema}.nlp_predictions_inbox (qr_id, item_linkid, model_name);
        """
        with self.conn.cursor() as cur:
            cur.execute(sql)
        self.conn.commit()

    def fetch_pending(
        self, model_name: str, limit: int, since_utc: Optional[datetime]
    ) -> List[Tuple]:
        """
        Returns tuples: (qr_id, item_linkid, authored_ts, text_raw, org_id, clinician_id)
        """
        if since_utc:
            filter_since = "and t.authored_ts >= %s"
            params = (model_name, since_utc, limit)
        else:
            filter_since = ""
            params = (model_name, limit)

        sql = f"""
        with pending as (
          select t.qr_id, t.item_linkid, t.authored_ts, t.text_raw, t.org_id, t.clinician_id
          from {self.schema}.nlp_prem_text t
          left join {self.schema}.nlp_predictions_inbox p
            on p.qr_id = t.qr_id
           and p.item_linkid = t.item_linkid
           and p.model_name = %s
          where p.qr_id is null
            and t.text_raw is not null
            and length(btrim(t.text_raw)) > 2
            {filter_since}
          order by t.authored_ts
          limit %s
        )
        select * from pending;
        """
        with self.conn.cursor() as cur:
            cur.execute(sql, params)
            rows = cur.fetchall()
        logger.info("Fetched %d pending rows", len(rows))
        return rows

    def upsert_predictions(self, rows: List[Tuple]):
        """
        rows must match:
        (run_id, model_name, qr_id, item_linkid, authored_ts,
         sentiment_label, sentiment_score, theme_primary, theme_secondary, created_at)
        """
        if not rows:
            return
        sql = f"""
        insert into {self.schema}.nlp_predictions_inbox
        (run_id, model_name, qr_id, item_linkid, authored_ts,
         sentiment_label, sentiment_score, theme_primary, theme_secondary, created_at)
        values %s
        on conflict (qr_id, item_linkid, model_name)
        do update set
          run_id = EXCLUDED.run_id,
          authored_ts = EXCLUDED.authored_ts,
          sentiment_label = EXCLUDED.sentiment_label,
          sentiment_score = EXCLUDED.sentiment_score,
          theme_primary = EXCLUDED.theme_primary,
          theme_secondary = EXCLUDED.theme_secondary,
          created_at = EXCLUDED.created_at;
        """
        with self.conn.cursor() as cur:
            execute_values(cur, sql, rows, page_size=500)
        self.conn.commit()
        logger.info("Upserted %d rows into %s.nlp_predictions_inbox", len(rows), self.schema)
