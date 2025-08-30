{{ config(materialized='view', schema='dq', tags=['dq']) }}

with a as (
  select
    a.qr_id,
    a.questionnaire_id,
    max(a.authored_ts)                                         as authored_ts,
    count(*)                                                   as n_answers_total,
    count(*) filter (where a.answer_kind='coding')             as n_answers_coding,
    count(*) filter (where a.answer_kind='string')             as n_answers_string,
    count(*) filter (where a.is_free_text)                     as n_free_text,
    count(*) filter (where a.is_scored)                        as n_answers_scored,
    count(*) filter (where a.answer_kind='coding' and a.has_ordinal)
                                                               as n_coding_with_ordinal,
    bool_or(a.is_nps)                                          as has_nps
  from {{ ref('stg_answers') }} a
  group by 1,2
),
expected as (
  -- what we "should" see: # of leaf items (and # scored leaf items) for that questionnaire
  select
    r.qr_id,
    r.questionnaire_id,
    count(*) filter (where i.is_leaf)                          as expected_items_leaf,
    count(*) filter (where i.is_leaf and i.is_scored)          as expected_items_scored
  from {{ ref('stg_responses') }} r
  left join {{ ref('stg_items') }} i
    on i.questionnaire_id = r.questionnaire_id
  group by 1,2
),
joined as (
  select
    coalesce(a.qr_id, e.qr_id)               as qr_id,
    coalesce(a.questionnaire_id, e.questionnaire_id) as questionnaire_id,
    a.authored_ts,
    coalesce(a.n_answers_total, 0)           as n_answers_total,
    coalesce(a.n_answers_coding, 0)          as n_answers_coding,
    coalesce(a.n_answers_string, 0)          as n_answers_string,
    coalesce(a.n_free_text, 0)               as n_free_text,
    coalesce(a.n_answers_scored, 0)          as n_answers_scored,
    coalesce(a.n_coding_with_ordinal, 0)     as n_coding_with_ordinal,
    coalesce(a.has_nps, false)               as has_nps,
    coalesce(e.expected_items_leaf, 0)       as expected_items_leaf,
    coalesce(e.expected_items_scored, 0)     as expected_items_scored
  from a
  full outer join expected e
    on a.qr_id = e.qr_id
)
select
  j.*,
  case when expected_items_leaf   > 0 then n_answers_total  ::numeric / expected_items_leaf   else null end as completion_ratio_total,
  case when expected_items_scored > 0 then n_answers_scored ::numeric / expected_items_scored else null end as completion_ratio_scored,
  case when n_answers_coding      > 0 then n_coding_with_ordinal::numeric / n_answers_coding  else null end as pct_mapped_ordinal
from joined j
