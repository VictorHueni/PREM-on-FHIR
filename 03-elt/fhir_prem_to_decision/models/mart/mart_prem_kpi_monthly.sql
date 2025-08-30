-- models/mart/mart_prem_kpi_monthly.sql
{{ config(materialized='view', schema='mart') }}
select
  date_trunc('month', period_date)::date as period_month,
  org_id, clinician_id, encounter_class,
  sum(responses_n) as responses_n,
  sum(patients_n)  as patients_n,
  sum(encounters_n) as encounters_n,
  avg(overall_score_pct_mean)   as overall_score_pct_mean,
  avg(overall_top_box_pct_mean) as overall_top_box_pct_mean,
  avg(overall_top2_box_pct_mean) as overall_top2_box_pct_mean
from {{ ref('mart_prem_kpi_daily') }}
group by 1,2,3,4
