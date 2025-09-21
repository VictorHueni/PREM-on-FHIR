{{ config(
  materialized='table',
  indexes=[
    {'columns':['qr_id'], 'unique':True},
    {'columns':['org_id','qr_date']},
    {'columns':['clinician_id','qr_date']}
  ]
) }}

with resp as (
  select
    qr_id,
    questionnaire_id,
    authored_ts,
    (authored_ts at time zone '{{ var("report_tz","UTC") }}')::date  as qr_date,
    date_trunc('week',  authored_ts at time zone '{{ var("report_tz","UTC") }}')::date as qr_week_start,
    date_trunc('month', authored_ts at time zone '{{ var("report_tz","UTC") }}')::date as qr_month_start,
    patient_id, 
    encounter_id, 
    clinician_id, 
    org_id
  from {{ ref('stg_responses') }}
),

ans as (
  select
    qr_id,
    questionnaire_id,
    -- only scored/ordinal answers participate in PREM score & top-box metrics
    case when is_scored and has_ordinal then score_pct end                      as score_pct_for_overall,
    case when is_scored and has_ordinal then answer_is_top_box::int end         as top_box_int,
    case when is_scored and has_ordinal then answer_is_top2_box::int end        as top2_box_int,
    case when is_scored and has_ordinal then 1 end                              as is_scored_answered_int,
    item_linkid,
    -- any answer present for the item (for total answered)
    1 as any_answer_int
  from {{ ref('fact_prem_answer') }}
),

expected as (
  -- expected leaf+scored items per questionnaire; repeats collapsed
  select
    questionnaire_key as questionnaire_id,
    count(distinct linkid) as items_scored_expected
  from {{ ref('stg_items') }}
  where is_leaf = true and coalesce(is_scored, true)
  group by 1
),

overalls as (
  select
    qr_id,
    questionnaire_id,
    avg(score_pct_for_overall)                                              as overall_score_pct,
    avg(top_box_int)                                                        as overall_top_box_pct,
    avg(top2_box_int)                                                       as overall_top2_box_pct,
    count(distinct case when any_answer_int=1 then item_linkid end)         as items_answered_total,
    count(distinct case when is_scored_answered_int=1 then item_linkid end) as items_scored_answered
  from ans
  group by 1,2
),

txt as (
  -- free text counters at response level (PoC)
  select
    qr_id,
    count(*) filter (where is_free_text) as free_text_count,
    (count(*) filter (where is_free_text) > 0) as has_comment_bool
  from {{ ref('fact_prem_answer') }}
  group by 1
),

domain_json as (
  -- convenience: a compact per-domain JSON for quick dashboard pulls
  select
    qr_id,
    jsonb_object_agg(domain_key,
      jsonb_build_object(
        'score_pct', domain_score_pct,
        'top_box_pct', domain_top_box_pct,
        'top2_box_pct', domain_top2_box_pct,
        'items_answered', items_answered_in_domain,
        'items_expected', items_expected_in_domain,
        'completeness_pct', domain_completeness_pct
      )
    ) as domain_metrics_json
  from {{ ref('fact_prem_response_domain') }}
  group by 1
)

select
  -- core response identifiers
  r.qr_id,
  r.questionnaire_id,

  -- foreign keys
  r.patient_id, 
  r.encounter_id, 
  r.clinician_id, 
  r.org_id,

  r.authored_ts, 
  r.qr_date, 
  r.qr_week_start, 
  r.qr_month_start,

  -- coverage counts
  o.items_answered_total,
  o.items_scored_answered,
  e.items_scored_expected,

  -- completeness
  case
    when e.items_scored_expected is null or e.items_scored_expected=0 then null
    else o.items_scored_answered::numeric / e.items_scored_expected
  end as response_completeness_pct,

  -- overall metrics
  o.overall_score_pct,
  o.overall_top_box_pct,
  o.overall_top2_box_pct,

  -- text PoC
  t.free_text_count,
  t.has_comment_bool,

  -- per-domain convenience
  dj.domain_metrics_json

from resp r
left join overalls o on o.qr_id = r.qr_id and o.questionnaire_id = r.questionnaire_id
left join expected e on e.questionnaire_id = r.questionnaire_id
left join txt t       on t.qr_id = r.qr_id
left join domain_json dj on dj.qr_id = r.qr_id