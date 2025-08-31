{{ config(
    on_schema_change='sync_all_columns',
) }}

with base as (
  select * from {{ ref('nlp_prem_text') }}
),
scored as (
  select
      p.*,
      row_number() over (
        partition by p.qr_id, p.item_linkid
        order by coalesce(p.created_at, now()) desc
      ) as rn_latest
  from {{ ref('nlp_predictions_inbox') }} p
)
select
    b.qr_id,
    b.item_linkid,
    b.questionnaire_id,
    b.org_id,
    b.clinician_id,
    b.encounter_id,
    b.patient_id,
    b.authored_ts,
    b.period_month,
    b.text_raw,

    -- predictions (latest only; nulls allowed if not scored yet)
    s.run_id,
    s.model_name,
    coalesce(s.sentiment_label, 'unscored')     as sentiment_label,
    s.sentiment_score,
    s.theme_primary,
    s.theme_secondary,
    s.created_at as prediction_created_at
from base b
left join scored s
  on s.qr_id = b.qr_id
 and s.item_linkid = b.item_linkid
 and s.rn_latest = 1
