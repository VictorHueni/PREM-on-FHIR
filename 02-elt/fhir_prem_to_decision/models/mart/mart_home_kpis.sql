{{ config(materialized='table', schema='mart') }}

with base as (
  select
    fr.qr_id,
    fr.patient_id,
    fr.org_id,
    fr.clinician_id,
    fr.questionnaire_id,
    fr.authored_ts::date as qr_date
  from {{ ref('fact_prem_response') }} fr
  -- (Metabase filter mapping will trim by date/org/clinician/questionnaire)
),
dq as (
  select
    qr_id,
    completion_ratio_scored,
    has_nps,
    n_free_text
  from {{ ref('dq_response_rollup') }}
),
joined as (
  select
    b.*,
    d.completion_ratio_scored,
    (d.has_nps)::int as has_nps_int,
    (d.n_free_text > 0)::int as has_freetext_int
  from base b
  left join dq d using (qr_id)
)
select
  count(*)                                         as responses_total,
  count(*) filter (where qr_date >= current_date - 30) AS responses_last_30d,
  count(distinct patient_id)                        as patients_total,
  avg(completion_ratio_scored)                      as avg_completion_scored,
  avg(has_nps_int)::numeric                         as pct_with_nps,
  avg(has_freetext_int)::numeric                    as pct_with_freetext
from joined
