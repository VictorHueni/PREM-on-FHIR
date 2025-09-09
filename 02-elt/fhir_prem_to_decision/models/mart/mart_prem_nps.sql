{{ config(materialized='table') }}

with nps_raw as (
  select
    qr_id,
    authored_ts,
    qr_date,
    qr_week_start,
    qr_month_start,
    org_id,
    clinician_id,
    encounter_id,
    patient_id,
    numeric_value as nps_score,
    nps_bucket
  from {{ ref('fact_prem_answer') }}
  where is_nps
),

agg as (
  select
    -- time grains
    qr_date,
    qr_week_start,
    qr_month_start,

    -- dimensions
    org_id,
    clinician_id,
    encounter_id,
    patient_id,

    -- bucket counts (portable)
    sum(case when nps_bucket = 'promoter'  then 1 else 0 end) as promoters,
    sum(case when nps_bucket = 'passive'   then 1 else 0 end) as passives,
    sum(case when nps_bucket = 'detractor' then 1 else 0 end) as detractors,
    count(*)                                                  as total_responses
  from nps_raw
  group by
    qr_date, qr_week_start, qr_month_start,
    org_id, clinician_id, encounter_id, patient_id
)

select
  *,
  case when total_responses > 0
       then 100.0 * ((promoters::numeric - detractors::numeric) / total_responses::numeric)
  end as nps_score_pct
from agg
