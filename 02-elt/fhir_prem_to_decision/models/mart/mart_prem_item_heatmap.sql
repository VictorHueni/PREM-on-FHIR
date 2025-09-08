{{ config(
  materialized='table',
  schema='mart',
  indexes=[
    {'columns':['period_month','org_id']},
    {'columns':['questionnaire_id','item_linkid']}
  ]
) }}

-- Base answers (one row per response × item × answer_ordinal)
with a as (
  select
    fa.qr_month_start                                              as period_month,
    fa.org_id,
    fa.questionnaire_id,
    fa.item_linkid,
    fa.domain_key,
    fa.qr_id,

    -- keep score for means, but ONLY when scored + ordinal
    case when fa.is_scored and fa.has_ordinal then fa.score_pct end       as score_pct_scored,

    -- clean integer flags for buckets (correct denominator = scored+ordinal)
    (fa.is_scored and fa.has_ordinal)::int                                as scored_ord_int,
    (fa.is_scored and fa.has_ordinal and fa.answer_is_bottom_box)::int    as bottom_box_int,
    (fa.is_scored and fa.has_ordinal and fa.answer_is_top_box)::int       as top_box_int,
    (fa.is_scored and fa.has_ordinal and fa.answer_is_top2_box)::int      as top2_box_int
  from {{ ref('fact_prem_answer') }} fa
  where fa.is_leaf
    and fa.is_scored = true
),

-- Item metadata (includes the desired item_order and question text)
items as (
  select
    questionnaire_key as questionnaire_id,
    linkid            as item_linkid,
    item_order,
    question_text
  from {{ ref('stg_items') }}
),

-- Org details
orgs as (
  select
    org_id,
    name as org_name
  from {{ ref('dim_organization') }}
)

select
  a.period_month,
  a.org_id,
  o.org_name,
  a.questionnaire_id,
  a.item_linkid,
  a.domain_key,

  /* counts */
  sum(a.scored_ord_int)                                  as denom_n,
  count(distinct a.qr_id)                                as responses_n,
  sum(a.bottom_box_int)                                  as poor_n,
  (sum(a.scored_ord_int) - sum(a.bottom_box_int) - sum(a.top_box_int)) as good_n,
  sum(a.top_box_int)                                     as very_good_n,

  /* rates */
  avg(a.score_pct_scored)                                as mean_score_pct,
  avg(a.top_box_int)                                     as top_box_pct,
  avg(a.top2_box_int)                                    as top2_box_pct,
  avg(a.bottom_box_int)                                  as problem_rate_pct,

  /* presentation */
  max(i.question_text)                                   as question_text,
  min(i.item_order)                                      as question_order,

  -- NEW: stable ordered label you can group by directly
  concat('Q', lpad(min(i.item_order)::text, 2, '0'),
         ' — ', left(max(i.question_text), 120))         as question_label_ordered
from a
left join items i
  on i.questionnaire_id = a.questionnaire_id
 and i.item_linkid      = a.item_linkid
left join orgs o
  on o.org_id = a.org_id
group by 1,2,3,4,5,6