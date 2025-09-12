{{ config(
  materialized='table',
  schema='mart',
  indexes=[
    {'columns':['period_month','entity_type']},
    {'columns':['entity_id']},
    {'columns':['is_outlier']}
  ]
) }}

-- Tunables (override with --vars '{outlier_min_n: 5, outlier_sigma: 2.0}')
{% set MIN_N = var('outlier_min_n', 5) | int %}
{% set SIGMA = var('outlier_sigma', 2.0) | float %}

with base as (
  select
    qr_month_start::date as period_month,
    org_id,
    clinician_id,
    overall_score_pct
  from {{ ref('fact_prem_response') }}
),

-- ORG level
org_month as (
  select
    period_month,
    org_id                              as entity_id,
    'org'::text                         as entity_type,
    count(*)                            as responses_n,
    avg(overall_score_pct)              as overall_score_pct_mean
  from base
  group by 1,2,3
),
org_stats as (
  select
    period_month,
    avg(overall_score_pct_mean)         as network_mean,
    stddev_samp(overall_score_pct_mean) as network_stddev
  from org_month
  group by 1
),
org_z as (
  select
    o.period_month,
    o.entity_type,
    o.entity_id,
    o.responses_n,
    o.overall_score_pct_mean,
    s.network_mean,
    s.network_stddev,
    case
      when s.network_stddev is null or s.network_stddev = 0 or o.responses_n < {{ MIN_N }}
        then null
      else (o.overall_score_pct_mean - s.network_mean) / s.network_stddev
    end as z_score,
    case when s.network_stddev is null then null else s.network_mean - {{ SIGMA }} * s.network_stddev end as cl_lower,
    case when s.network_stddev is null then null else s.network_mean + {{ SIGMA }} * s.network_stddev end as cl_upper
  from org_month o
  left join org_stats s using (period_month)
),

-- CLINICIAN level
clin_month as (
  select
    period_month,
    clinician_id                         as entity_id,
    'clinician'::text                    as entity_type,
    count(*)                             as responses_n,
    avg(overall_score_pct)               as overall_score_pct_mean
  from base
  where clinician_id is not null
  group by 1,2,3
),
clin_stats as (
  select
    period_month,
    avg(overall_score_pct_mean)          as network_mean,
    stddev_samp(overall_score_pct_mean)  as network_stddev
  from clin_month
  group by 1
),
clin_z as (
  select
    c.period_month,
    c.entity_type,
    c.entity_id,
    c.responses_n,
    c.overall_score_pct_mean,
    s.network_mean,
    s.network_stddev,
    case
      when s.network_stddev is null or s.network_stddev = 0 or c.responses_n < {{ MIN_N }}
        then null
      else (c.overall_score_pct_mean - s.network_mean) / s.network_stddev
    end as z_score,
    case when s.network_stddev is null then null else s.network_mean - {{ SIGMA }} * s.network_stddev end as cl_lower,
    case when s.network_stddev is null then null else s.network_mean + {{ SIGMA }} * s.network_stddev end as cl_upper
  from clin_month c
  left join clin_stats s using (period_month)
),

z_union as (
  select * from org_z
  union all
  select * from clin_z
),

-- Add friendly labels from dims (use .name)
labeled as (
  select
    z.period_month,
    z.entity_type,
    z.entity_id,
    case
      when z.entity_type = 'org'
        then coalesce(o.name, z.entity_id::text)
      else coalesce(p.full_name, z.entity_id::text)
    end                                            as entity_label,
    z.responses_n,
    z.overall_score_pct_mean,
    z.network_mean,
    z.network_stddev,
    z.z_score,
    z.cl_lower,
    z.cl_upper,
    (z.z_score is not null and abs(z.z_score) >= {{ SIGMA }}) as is_outlier
  from z_union z
  left join {{ ref('dim_organization') }}  o on z.entity_type = 'org'       and z.entity_id = o.org_id
  left join {{ ref('dim_practitioner') }}  p on z.entity_type = 'clinician' and z.entity_id = p.practitioner_id
)

select
  period_month,
  entity_type,
  entity_id,
  entity_label,
  responses_n,
  overall_score_pct_mean,
  network_mean,
  network_stddev,
  z_score,
  cl_lower,
  cl_upper,
  is_outlier
from labeled
order by period_month desc, entity_type, z_score desc nulls last
