{{ config(
  materialized='table',
  schema='mart',
  indexes=[ {'columns':['period_month','org_id']}, {'columns':['age_band','gender_norm']} ]
) }}

with r as (
  select
    qr_month_start as period_month,
    qr_date,
    qr_id, patient_id, org_id, encounter_id, clinician_id,
    overall_score_pct, overall_top_box_pct, overall_top2_box_pct
  from {{ ref('fact_prem_response') }}
),
p as (
  select patient_id, gender_norm, birth_date
  from {{ ref('dim_patient') }}
),
with_age as (
  select
    r.*,
    p.gender_norm,
    -- derive age at event, then band
    extract(year from age(r.qr_date::timestamp, p.birth_date::timestamp))::int as age_at_event,
    case
      when p.birth_date is null then null
      when extract(year from age(r.qr_date::timestamp, p.birth_date::timestamp)) < 18 then '0-17'
      when extract(year from age(r.qr_date::timestamp, p.birth_date::timestamp)) between 18 and 34 then '18-34'
      when extract(year from age(r.qr_date::timestamp, p.birth_date::timestamp)) between 35 and 49 then '35-49'
      when extract(year from age(r.qr_date::timestamp, p.birth_date::timestamp)) between 50 and 64 then '50-64'
      when extract(year from age(r.qr_date::timestamp, p.birth_date::timestamp)) between 65 and 79 then '65-79'
      else '80+'
    end as age_band
  from r
  left join p using (patient_id)
),
domain_daily as (
  -- per-response domain metrics joined to response for grouping
  select
    fr.qr_month_start as period_month,
    fr.org_id,
    d.qr_id,
    d.domain_key,
    d.domain_score_pct, d.domain_top_box_pct, d.domain_top2_box_pct, d.domain_completeness_pct
  from {{ ref('fact_prem_response') }} fr
  join {{ ref('fact_prem_response_domain') }} d using (qr_id, questionnaire_id)
),
domain_slice as (
  select
    w.period_month, w.org_id, w.age_band, w.gender_norm, dd.domain_key,
    avg(dd.domain_score_pct)           as domain_score_pct_mean,
    avg(dd.domain_top_box_pct)         as domain_top_box_pct_mean,
    avg(dd.domain_top2_box_pct)        as domain_top2_box_pct_mean,
    avg(dd.domain_completeness_pct)    as domain_completeness_pct_mean
  from with_age w
  join domain_daily dd on dd.qr_id = w.qr_id and dd.period_month = w.period_month and dd.org_id = w.org_id
  group by 1,2,3,4,5
),
domain_json as (
  select
    period_month, org_id, age_band, gender_norm,
    jsonb_object_agg(
      domain_key,
      jsonb_build_object(
        'score_pct_mean', domain_score_pct_mean,
        'top_box_pct_mean', domain_top_box_pct_mean,
        'top2_box_pct_mean', domain_top2_box_pct_mean,
        'completeness_pct_mean', domain_completeness_pct_mean
      )
    ) as domain_metrics_json
  from domain_slice
  group by 1,2,3,4
)

select
  w.period_month,
  w.org_id,
  w.age_band,
  w.gender_norm,

  count(distinct w.qr_id)                     as responses_n,
  avg(w.overall_score_pct)                    as overall_score_pct_mean,
  avg(w.overall_top_box_pct)                  as overall_top_box_pct_mean,
  avg(w.overall_top2_box_pct)                 as overall_top2_box_pct_mean,

  dj.domain_metrics_json

from with_age w
left join domain_json dj
  on dj.period_month = w.period_month
 and dj.org_id = w.org_id
 and dj.age_band = w.age_band
 and dj.gender_norm = w.gender_norm
group by 1,2,3,4, dj.domain_metrics_json
