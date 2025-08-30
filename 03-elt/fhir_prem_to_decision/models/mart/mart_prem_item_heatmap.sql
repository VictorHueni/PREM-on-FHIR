{{ config(
  materialized='table',
  schema='mart',
  indexes=[
    {'columns':['period_month','org_id']},
    {'columns':['questionnaire_id','item_linkid']}
  ]
) }}

with a as (
  select
    qr_month_start   as period_month,
    org_id,
    questionnaire_id,
    item_linkid,
    domain_key,
    -- scored-only flags
    case when is_scored and has_ordinal then score_pct end                as score_pct_scored,
    case when is_scored and has_ordinal then answer_is_top_box::int end   as top_box_int,
    case when is_scored and has_ordinal then answer_is_top2_box::int end  as top2_box_int,
    case when is_scored and has_ordinal then answer_is_bottom_box::int end as bottom_box_int,
    qr_id
  from {{ ref('fact_prem_answer') }}
  where is_leaf
)

select
  period_month,
  org_id,
  questionnaire_id,
  item_linkid,
  domain_key,

  count(*)                              as answers_n,
  count(distinct qr_id)                 as responses_n,

  avg(score_pct_scored)                 as mean_score_pct,
  avg(top_box_int)                      as top_box_pct,
  avg(top2_box_int)                     as top2_box_pct,
  avg(bottom_box_int)                   as problem_rate_pct

from a
group by 1,2,3,4,5
