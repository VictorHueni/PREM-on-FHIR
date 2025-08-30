{{ config(
  materialized='table',
  schema='mart',
  indexes=[
    {'columns':['period_date','org_id']},
    {'columns':['period_date','clinician_id']},
    {'columns':['encounter_class']}
  ]
) }}

with base as (
  select
    r.qr_id,
    r.patient_id, r.encounter_id, r.clinician_id, r.org_id,
    r.qr_date as period_date,
    r.overall_score_pct,
    r.overall_top_box_pct,
    r.overall_top2_box_pct
  from {{ ref('fact_prem_response') }} r
),
enc as (
  select encounter_id, encounter_class
  from {{ ref('dim_encounter') }}
),
b as (
  select
    base.*,
    coalesce(enc.encounter_class, 'UNKNOWN') as encounter_class
  from base
  left join enc on enc.encounter_id = base.encounter_id
),

-- per-domain metrics rolled up to daily grouping, packed as JSON for fast pulls
domain_daily as (
  select
    fpr.qr_date as period_date,
    fpr.org_id, fpr.clinician_id,
    coalesce(enc.encounter_class, 'UNKNOWN') as encounter_class,
    d.domain_key,
    avg(d.domain_score_pct)      as domain_score_pct_mean,
    avg(d.domain_top_box_pct)    as domain_top_box_pct_mean,
    avg(d.domain_top2_box_pct)   as domain_top2_box_pct_mean,
    avg(d.domain_completeness_pct) as domain_completeness_pct_mean
  from {{ ref('fact_prem_response_domain') }} d
  join {{ ref('fact_prem_response') }} fpr using (qr_id, questionnaire_id)
  left join {{ ref('dim_encounter') }} enc on enc.encounter_id = fpr.encounter_id
  group by 1,2,3,4,5
),
domain_json as (
  select
    period_date, org_id, clinician_id, encounter_class,
    jsonb_object_agg(
      domain_key,
      jsonb_build_object(
        'score_pct_mean', domain_score_pct_mean,
        'top_box_pct_mean', domain_top_box_pct_mean,
        'top2_box_pct_mean', domain_top2_box_pct_mean,
        'completeness_pct_mean', domain_completeness_pct_mean
      )
    ) as domain_metrics_json
  from domain_daily
  group by 1,2,3,4
)

select
  b.period_date,
  b.org_id,
  b.clinician_id,
  b.encounter_class,

  -- coverage
  count(distinct b.qr_id)              as responses_n,
  count(distinct b.patient_id)         as patients_n,
  count(distinct b.encounter_id)       as encounters_n,

  -- overall means (per-response)
  avg(b.overall_score_pct)             as overall_score_pct_mean,
  avg(b.overall_top_box_pct)           as overall_top_box_pct_mean,
  avg(b.overall_top2_box_pct)          as overall_top2_box_pct_mean,

  dj.domain_metrics_json               as domain_metrics_json

from b
left join domain_json dj
  on dj.period_date = b.period_date
 and dj.org_id = b.org_id
 and dj.clinician_id = b.clinician_id
 and dj.encounter_class = b.encounter_class
group by 1,2,3,4, dj.domain_metrics_json
