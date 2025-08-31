{{ config(
  materialized='table',
  schema='mart',
  indexes=[ {'columns':['period_month','entity_type']}, {'columns':['entity_id']} ]
) }}

with base as (
  select
    qr_month_start as period_month,
    org_id, clinician_id,
    overall_score_pct
  from {{ ref('fact_prem_response') }}
),

org_month as (
  select
    period_month,
    org_id as entity_id,
    'org'::text as entity_type,
    count(*) as responses_n,
    avg(overall_score_pct) as overall_score_pct_mean
  from base
  group by 1,2,3
),
org_stats as (
  select
    period_month,
    avg(overall_score_pct_mean) as network_mean,
    stddev_samp(overall_score_pct_mean) as network_stddev
  from org_month
  group by 1
),
org_z as (
  select
    o.period_month, o.entity_type, o.entity_id, o.responses_n, o.overall_score_pct_mean,
    s.network_mean, s.network_stddev,
    case when s.network_stddev is null or s.network_stddev = 0 then null
         else (o.overall_score_pct_mean - s.network_mean) / s.network_stddev end as z_score
  from org_month o
  left join org_stats s using (period_month)
),

clin_month as (
  select
    period_month,
    clinician_id as entity_id,
    'clinician'::text as entity_type,
    count(*) as responses_n,
    avg(overall_score_pct) as overall_score_pct_mean
  from base
  where clinician_id is not null
  group by 1,2,3
),
clin_stats as (
  select
    period_month,
    avg(overall_score_pct_mean) as network_mean,
    stddev_samp(overall_score_pct_mean) as network_stddev
  from clin_month
  group by 1
),
clin_z as (
  select
    c.period_month, c.entity_type, c.entity_id, c.responses_n, c.overall_score_pct_mean,
    s.network_mean, s.network_stddev,
    case when s.network_stddev is null or s.network_stddev = 0 then null
         else (c.overall_score_pct_mean - s.network_mean) / s.network_stddev end as z_score
  from clin_month c
  left join clin_stats s using (period_month)
)

select
  period_month, entity_type, entity_id, responses_n, overall_score_pct_mean,
  network_mean, network_stddev, z_score,
  (abs(z_score) >= 2) as is_outlier
from org_z
union all
select
  period_month, entity_type, entity_id, responses_n, overall_score_pct_mean,
  network_mean, network_stddev, z_score,
  (abs(z_score) >= 2) as is_outlier
from clin_z
