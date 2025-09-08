-- models/mart/mart_prem_kpi_domains.sql
{{ config(
  materialized='table',
  schema='mart',
  indexes=[ {'columns':['period_month','org_id','domain_key']} ]
) }}

with src as (
  select period_date, org_id, domain_metrics_json
  from {{ ref('mart_prem_kpi_daily') }}
  where domain_metrics_json is not null
),
exploded as (
  select
    date_trunc('month', period_date)::date as period_month,
    org_id,
    d.key                                      as domain_key,
    (d.value->>'score_pct_mean')::numeric      as score_pct_mean,
    (d.value->>'top2_box_pct_mean')::numeric   as top2_box_pct_mean
  from src
  cross join lateral jsonb_each(src.domain_metrics_json) as d(key, value)
),
monthly as (
  select
    period_month, org_id, domain_key,
    avg(score_pct_mean)      as score_pct_mean,
    avg(top2_box_pct_mean)   as top2_box_pct_mean
  from exploded
  group by 1,2,3
)

select * from monthly
