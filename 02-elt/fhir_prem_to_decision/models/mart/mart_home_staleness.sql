{{ config(materialized='table', schema='mart') }}

with
-- volumes by org × questionnaire
fr as (
  select
    org_id,
    questionnaire_id,
    count(*)                   as responses_n,
    count(distinct patient_id) as patients_n
  from {{ ref('fact_prem_response') }}
  group by 1,2
),

-- questionnaire staleness/design facts (one row per questionnaire)
dq_raw as (
  select
    org_id,
    questionnaire_id,
    questionnaire_version,
    item_count_leaf,
    item_count_scored,
    last_seen_in_answers,
    questionnaire_last_updated,
    days_since_last_answer,
    days_since_last_update,
    row_number() over (
      partition by org_id, questionnaire_id
      order by
        questionnaire_last_updated desc nulls last,
        last_seen_in_answers      desc nulls last
    ) as rn
  from {{ ref('dq_questionnaire_staleness') }}
),
dq as (
  select * from dq_raw where rn = 1
),


-- per-response rollup for coverage/completion
roll as (
  select
    rr.qr_id,
    rr.completion_ratio_scored,
    rr.has_nps,
    rr.n_free_text
  from {{ ref('dq_response_rollup') }} rr
),

-- org × questionnaire coverage & completion (averaged over responses)
org_qr as (
  select
    f.org_id,
    f.questionnaire_id,
    f.responses_n,
    f.patients_n,
    avg((r.has_nps)::int)::numeric         as pct_with_nps,
    avg((r.n_free_text > 0)::int)::numeric as pct_with_freetext,
    avg(r.completion_ratio_scored)         as avg_completion_scored
  from {{ ref('fact_prem_response') }} fr0
  join fr f using (org_id, questionnaire_id)
  left join roll r on r.qr_id = fr0.qr_id
  group by 1,2,3,4
),

-- join in questionnaire staleness/design
base as (
  select
    o.org_id,
    o.questionnaire_id,
    o.responses_n,
    o.patients_n,
    o.pct_with_nps,
    o.pct_with_freetext,
    o.avg_completion_scored,
    d.item_count_leaf,
    d.item_count_scored,
    d.last_seen_in_answers,
    d.days_since_last_answer,
    d.questionnaire_last_updated,
    d.days_since_last_update
  from org_qr o
  left join dq d
    on d.org_id = o.org_id
   and d.questionnaire_id = o.questionnaire_id
),

-- thresholds (override via dbt vars if you like)
params as (
  select
    {{ var('stale_warn_days', 7) }}::int  as warn_days,
    {{ var('stale_red_days', 30) }}::int  as red_days
),

scored as (
  select
    b.*,
    p.warn_days, p.red_days,

    case
      when b.days_since_last_answer is null then 'unknown'
      when b.days_since_last_answer <  p.warn_days then 'green'
      when b.days_since_last_answer <  p.red_days  then 'amber'
      else 'red'
    end as answer_freshness,

    case
      when b.days_since_last_update is null then 'unknown'
      when b.days_since_last_update <  p.warn_days then 'green'
      when b.days_since_last_update <  p.red_days  then 'amber'
      else 'red'
    end as update_freshness,

    case
      when b.days_since_last_answer is null then 3
      when b.days_since_last_answer <  p.warn_days then 0
      when b.days_since_last_answer <  p.red_days  then 1
      else 2
    end as answer_severity,

    case
      when b.days_since_last_update is null then 3
      when b.days_since_last_update <  p.warn_days then 0
      when b.days_since_last_update <  p.red_days  then 1
      else 2
    end as update_severity,

    (coalesce(
       case when b.days_since_last_answer is null then 3
            when b.days_since_last_answer <  p.warn_days then 0
            when b.days_since_last_answer <  p.red_days  then 1
            else 2 end, 3) * 2
     +
     coalesce(
       case when b.days_since_last_update is null then 3
            when b.days_since_last_update <  p.warn_days then 0
            when b.days_since_last_update <  p.red_days  then 1
            else 2 end, 3)
    ) as staleness_score
  from base b
  cross join params p
),

orgs as (
  select org_id, name as org_name
  from {{ ref('dim_organization') }}
)

select
  s.org_id,
  o.org_name,
  s.questionnaire_id,
  -- a stable unique id for tests / BI:
  md5(concat_ws('|', s.org_id::text, s.questionnaire_id::text)) as staleness_id,
  s.responses_n,
  s.patients_n,
  s.pct_with_nps,
  s.pct_with_freetext,
  s.avg_completion_scored,
  s.item_count_leaf,
  s.item_count_scored,
  s.last_seen_in_answers,
  s.days_since_last_answer,
  s.answer_freshness,
  s.answer_severity,
  s.questionnaire_last_updated,
  s.days_since_last_update,
  s.update_freshness,
  s.update_severity,
  s.staleness_score
from scored s
left join orgs o using (org_id)
