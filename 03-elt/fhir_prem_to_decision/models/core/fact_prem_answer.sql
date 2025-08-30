{{ config(
  materialized='table',
  indexes=[
    {'columns':['qr_id']},
    {'columns':['org_id','authored_ts']},
    {'columns':['clinician_id','authored_ts']},
    {'columns':['item_linkid']},
    {'columns':['questionnaire_id','item_linkid']}
  ]
) }}

with a as (
  select
    -- grain
    qr_id,
    item_linkid,
    answer_ordinal,
    answer_id,

    -- timing (rebuild buckets in reporting TZ to be safe)
    authored_ts,
    (authored_ts at time zone '{{ var("report_tz","UTC") }}')::date                                   as qr_date,
    date_trunc('week',  authored_ts at time zone '{{ var("report_tz","UTC") }}')::date                as qr_week_start,
    date_trunc('month', authored_ts at time zone '{{ var("report_tz","UTC") }}')::date                as qr_month_start,

    -- questionnaire/item
    questionnaire_id,
    answer_kind,
    value_display, value_code, value_coding_system,
    value_string,  value_string_clean,
    numeric_value,
    has_ordinal,
    likert_max_for_item,
    score_pct,
    answer_is_top_box,
    answer_is_top2_box,
    answer_is_bottom_box,
    is_free_text,
    is_nps,
    nps_bucket,

    -- context ids
    patient_id,
    encounter_id,
    clinician_id,
    org_id,

    -- helpful ready-made metric
    age_at_authored
  from {{ ref('stg_answers') }}
),

i as (
  select
    questionnaire_key  as questionnaire_id,
    linkid             as item_linkid,
    is_leaf,
    is_scored,
    domain_key,
    domain_code_value,
    domain_code_system,
    repeats
  from {{ ref('stg_items') }}
  where is_leaf = true
),

d_enc as (
  select encounter_id, encounter_type_norm, class_group, is_inpatient
  from {{ ref('stg_dim_encounters') }}
),

d_org as (
  select org_id, org_kind_norm, org_slug
  from {{ ref('stg_dim_organizations') }}
),

d_prac as (
  select practitioner_id, clinician_slug, clinician_pseudonym
  from {{ ref('stg_dim_practitioners') }}
),

d_pat as (
  select patient_id, gender_norm, age_band_current
  from {{ ref('stg_dim_patients') }}
)

select
  -- PK columns
  a.qr_id,
  a.item_linkid,
  a.answer_ordinal,

  -- stable answer id (handy for joins to NLP)
  a.answer_id,

  -- time
  a.authored_ts, a.qr_date, a.qr_week_start, a.qr_month_start,

  -- questionnaire / item
  a.questionnaire_id,
  i.is_leaf,
  coalesce(i.is_scored, a.has_ordinal) as is_scored,
  i.domain_key,
  i.domain_code_value,
  i.domain_code_system,
  i.repeats,

  -- categorical + numeric shape
  a.answer_kind,
  a.value_display, a.value_code, a.value_coding_system,
  a.value_string, a.value_string_clean,
  a.numeric_value,
  a.has_ordinal,
  a.likert_max_for_item,
  a.score_pct,
  a.answer_is_top_box,
  a.answer_is_top2_box,
  a.answer_is_bottom_box,
  a.is_free_text,
  a.is_nps,
  a.nps_bucket,

  -- context ids
  a.patient_id, a.encounter_id, a.clinician_id, a.org_id,

  -- light denorm (BI-friendly)
  d_enc.encounter_type_norm,
  d_enc.class_group,
  d_enc.is_inpatient,
  d_org.org_kind_norm,
  d_org.org_slug,
  d_prac.clinician_slug,
  d_prac.clinician_pseudonym,
  d_pat.gender_norm,
  a.age_at_authored,
  /* age band at event (derive from continuous age) */
  case
    when a.age_at_authored is null then null
    when a.age_at_authored < 18 then '0-17'
    when a.age_at_authored between 18 and 34 then '18-34'
    when a.age_at_authored between 35 and 49 then '35-49'
    when a.age_at_authored between 50 and 64 then '50-64'
    when a.age_at_authored between 65 and 79 then '65-79'
    else '80+'
  end as age_band_at_authored

from a
left join i
  on i.questionnaire_id = a.questionnaire_id
 and i.item_linkid      = a.item_linkid
left join d_enc on d_enc.encounter_id       = a.encounter_id
left join d_org on d_org.org_id             = a.org_id
left join d_prac on d_prac.practitioner_id  = a.clinician_id
left join d_pat on d_pat.patient_id         = a.patient_id
where i.is_leaf = true
