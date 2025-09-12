{{ config(materialized='table', schema='mart') }}

with base as (
  select
    fr.qr_id,
    fr.questionnaire_id,
    fr.org_id,
    fr.patient_id,
    fr.authored_ts::date as qr_date
  from {{ ref('fact_prem_response') }} fr
),
dq as (
  select
    qr_id, completion_ratio_scored, has_nps, n_free_text
  from {{ ref('dq_response_rollup') }}
),
j as (
  select
    b.questionnaire_id,
    b.org_id,
    b.patient_id,
    b.qr_id,
    b.qr_date,
    d.completion_ratio_scored,
    (d.has_nps)::int as has_nps_int,
    (d.n_free_text > 0)::int as has_freetext_int
  from base b
  left join dq d using (qr_id)
)
select
  questionnaire_id,
  count(*)                                   as responses_n,
  count(distinct patient_id)                 as patients_n,
  avg(has_nps_int)::numeric                  as pct_with_nps,
  avg(has_freetext_int)::numeric             as pct_with_freetext,
  avg(completion_ratio_scored)               as avg_completion_scored
from j
group by 1
