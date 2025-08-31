with item_summary as (
  select
    -- Use the normalized key that matches stg_responses/stg_answers
    questionnaire_key                               as questionnaire_id,
    questionnaire_version,
    questionnaire_url,
    count(*) filter (where is_leaf)                 as item_count_leaf,
    count(*) filter (where is_leaf and is_scored)   as item_count_scored
  from {{ ref('stg_items') }}
  group by 1,2,3
),

answer_last_seen as (
  select
    questionnaire_id,                               -- already normalized in stg_answers
    max(authored_ts) as last_seen_in_answers
  from {{ ref('stg_answers') }}
  group by 1
),

q_meta as (
  select
    -- normalize to last URL segment; fall back to logical id text
    coalesce(
      nullif(regexp_replace((resource::jsonb->>'url')::text, '^.*/', ''), ''),
      questionnaire_id::text
    )                                 as questionnaire_id,      -- normalized
    (resource::jsonb->>'version')::text as questionnaire_version,
    (resource::jsonb->>'url')::text     as questionnaire_url,
    last_updated                        as questionnaire_last_updated
  from {{ source('raw','questionnaire_current') }}
)

select
  i.questionnaire_id,
  i.questionnaire_version,
  i.questionnaire_url,
  i.item_count_leaf,
  i.item_count_scored,

  a.last_seen_in_answers,
  q.questionnaire_last_updated,

  -- staleness clocks (reporting TZ for day boundaries)
  case when a.last_seen_in_answers is not null
       then (current_timestamp at time zone '{{ var("report_tz","UTC") }}')::date
          - (a.last_seen_in_answers   at time zone '{{ var("report_tz","UTC") }}')::date
  end as days_since_last_answer,

  case when q.questionnaire_last_updated is not null
       then (current_timestamp at time zone '{{ var("report_tz","UTC") }}')::date
          - (q.questionnaire_last_updated at time zone '{{ var("report_tz","UTC") }}')::date
  end as days_since_last_update

from item_summary i
left join answer_last_seen a
  on a.questionnaire_id = i.questionnaire_id
left join q_meta q
  on q.questionnaire_id = i.questionnaire_id
 and coalesce(q.questionnaire_version,'') = coalesce(i.questionnaire_version,'')