{{ config(materialized='table', schema=var('core_schema','core')) }}

with s as (
  select
    -- stable IDs
    md5(coalesce(i.questionnaire_key,'') || '|' || coalesce(i.linkid,'')) as item_id,

    -- join keys (for facts & Metabase filters)
    i.questionnaire_key  as questionnaire_id,     -- normalized ID matching stg_responses/stg_answers
    i.linkid,

    -- questionnaire metadata
    i.questionnaire_version,
    i.questionnaire_url,

    -- hierarchy / ordering
    i.parent_linkid,
    i.depth,
    i.path,
    i.item_order,

    -- labels
    i.question_text,
    i.question_type,

    -- value set / scale hints
    i.answer_valueset,
    i.valueset_key,
    i.likert_min,
    i.likert_max,

    -- domain tagging
    i.domain_key,
    i.domain_code_system,
    i.domain_code_value,
    i.domain_code_display,

    -- flags
    i.is_leaf,
    i.is_required,
    i.repeats,
    i.is_free_text,
    i.is_scored
  from {{ ref('stg_items') }} i
  where i.linkid is not null
)
select * from s
