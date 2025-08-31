-- One row per free-text answer with enough context for scoring.
with src as (
  select
      a.qr_id,
      a.item_linkid,
      a.questionnaire_id,       -- keep for reference
      a.org_id,
      a.clinician_id,
      a.encounter_id,
      a.patient_id,
      a.authored_ts,
      date_trunc('month', a.authored_ts)::date as period_month,
      trim(a.value_string)      as text_raw
  from {{ ref('stg_answers') }} a
  where a.is_free_text = true
    and a.value_string is not null
    and length(trim(a.value_string)) > 0
)

select
    qr_id,
    item_linkid,
    questionnaire_id,
    org_id,
    clinician_id,
    encounter_id,
    patient_id,
    authored_ts,
    period_month,
    text_raw
from src
