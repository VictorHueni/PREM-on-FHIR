{{ config(
    on_schema_change='append_new_columns'
) }}

-- This table is the handoff between your ML job and dbt.
-- Your ML job may INSERT into it repeatedly; we keep the latest per (qr_id, item_linkid) in downstream marts.

-- Empty pattern: create the structure; it may be empty until your first scoring run.
-- Use NOT NULL only for the business keys so the pipeline can land partial payloads safely.

select
    cast(null as text)                         as run_id,           -- ML run identifier (e.g. timestamp or UUID)
    cast(null as text)                         as model_name,       -- optional model/version
    cast(null as text)                         as qr_id,
    cast(null as text)                         as item_linkid,
    cast(null as timestamp with time zone)     as authored_ts,      -- echoed from source (optional)
    cast(null as text)                         as sentiment_label,  -- e.g. 'positive' | 'neutral' | 'negative'
    cast(null as double precision)             as sentiment_score,  -- e.g. -1..+1
    cast(null as text)                         as theme_primary,    -- short label like 'Environment'
    cast(null as text)                         as theme_secondary,  -- optional subtheme
    now()                                      as created_at        -- when this record landed
where false
