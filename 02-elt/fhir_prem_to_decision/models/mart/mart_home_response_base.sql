-- models/mart/mart_home_response_base.sql
{{ config(materialized='table', schema='mart') }}

with base as (
  select
    fr.qr_id,
    fr.patient_id,
    fr.org_id,
    fr.questionnaire_id,
    fr.authored_ts::date as period_date
  from {{ ref('fact_prem_response') }} fr
),
dq as (
  select
    qr_id,
    completion_ratio_scored,
    completion_ratio_total,
    (has_nps)::int                              as has_nps_int,
    (n_free_text > 0)::int                      as has_freetext_int
  from {{ ref('dq_response_rollup') }}
)

select
  b.period_date,
  b.org_id,
  b.questionnaire_id,
  b.qr_id,
  b.patient_id,
  dq.completion_ratio_total,
  dq.completion_ratio_scored,
  dq.has_nps_int,
  dq.has_freetext_int
from base b
left join dq using (qr_id)
