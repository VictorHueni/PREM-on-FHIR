{{ config(materialized='table') }}

with ans as (
  select
    qr_id,
    questionnaire_id,
    domain_key,
    -- restrict to scored/ordinal answers for PREM scoring
    case when is_scored and has_ordinal then score_pct end  as score_pct_for_domain,
    case when is_scored and has_ordinal then answer_is_top_box::int end  as top_box_int,
    case when is_scored and has_ordinal then answer_is_top2_box::int end as top2_box_int,
    -- collapse repeats by linkId at response-level (count once if any answer)
    item_linkid
  from {{ ref('fact_prem_answer') }}
  where is_leaf
),

expected as (
  -- expected items per questionnaire × domain (leaf, scored), repeats collapsed
  select
    questionnaire_key as questionnaire_id,
    domain_key,
    count(distinct linkid) as items_expected_in_domain
  from {{ ref('stg_items') }}
  where is_leaf = true and coalesce(is_scored, true)
  group by 1,2
),

agg as (
  select
    qr_id,
    questionnaire_id,
    domain_key,
    avg(score_pct_for_domain)                                   as domain_score_pct,
    avg(top_box_int)                                            as domain_top_box_pct,
    avg(top2_box_int)                                           as domain_top2_box_pct,
    count(distinct case when score_pct_for_domain is not null then item_linkid end) as items_answered_in_domain
  from ans
  group by 1,2,3
)

select
  a.qr_id,
  a.questionnaire_id,
  a.domain_key,
  a.domain_score_pct,
  a.domain_top_box_pct,
  a.domain_top2_box_pct,
  a.items_answered_in_domain,
  e.items_expected_in_domain,
  case
    when e.items_expected_in_domain is null or e.items_expected_in_domain = 0 then null
    else a.items_answered_in_domain::numeric / e.items_expected_in_domain
  end as domain_completeness_pct
from agg a
left join expected e
  on e.questionnaire_id = a.questionnaire_id
 and e.domain_key       = a.domain_key