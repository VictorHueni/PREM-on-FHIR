{{ config(materialized='view') }}

with qr as (
  select
    qr_id,
    authored_ts,
    -- Prefer canonical URL found in the JSON, else the reference column
    coalesce((resource::jsonb->>'questionnaire')::text, questionnaire_ref) as questionnaire_any,
    patient_ref,
    encounter_ref,
    author_ref,

    -- Airbyte lineage
    _airbyte_raw_id          as airbyte_raw_id,
    _airbyte_extracted_at    as loaded_at,
    _airbyte_generation_id   as airbyte_generation_id,
    _airbyte_meta::jsonb     as airbyte_meta
  from {{ source('raw', 'questionnaireresponse_current') }}
),

-- tease out URL vs relative id
qr_keys as (
  select
    q.*,
    case when questionnaire_any ~* '^https?://' then questionnaire_any end                            as questionnaire_canonical_url,
    case when questionnaire_any like 'Questionnaire/%' then split_part(questionnaire_any,'/',2) end    as questionnaire_logical_id
  from qr q
),

-- Questionnaire metadata by canonical URL
q_meta_url as (
  select
    (resource::jsonb->>'url')::text as questionnaire_canonical_url,
    questionnaire_id                as questionnaire_logical_id_meta,
    (resource::jsonb->>'version')::text as questionnaire_version_meta
  from {{ source('raw','questionnaire_current') }}
),

-- Fallback metadata by logical id
q_meta_id as (
  select
    questionnaire_id                as questionnaire_logical_id_meta,
    (resource::jsonb->>'url')::text as questionnaire_canonical_url_meta,
    (resource::jsonb->>'version')::text as questionnaire_version_meta
  from {{ source('raw','questionnaire_current') }}
),

enc as (
  select
    encounter_id,
    'Encounter/' || encounter_id as encounter_ref,
    org_ref,
    practitioner_ref
  from {{ source('raw','encounter_current') }}
),

base as (
  select
    k.qr_id,
    k.authored_ts,

    -- version via URL first, then by logical id
    coalesce(u.questionnaire_version_meta, i.questionnaire_version_meta) as questionnaire_version,

    -- questionnaire_id: last segment of canonical URL (e.g. NREQ), else logical id
    coalesce(
      case when k.questionnaire_canonical_url is not null
           then regexp_replace(k.questionnaire_canonical_url, '^.*/', '')
      end,
      k.questionnaire_logical_id
    ) as questionnaire_id,

    -- keep original refs
    k.patient_ref,
    k.encounter_ref,
    coalesce(k.author_ref, e.practitioner_ref) as clinician_ref,
    e.org_ref,

    -- clean ids (strip prefixes)
    nullif(split_part(coalesce(k.patient_ref, ''), '/', 2), '')                           as patient_id,
    nullif(split_part(coalesce(k.encounter_ref, ''), '/', 2), '')                         as encounter_id,
    nullif(split_part(coalesce(coalesce(k.author_ref, e.practitioner_ref), ''), '/', 2), '') as clinician_id,
    nullif(split_part(coalesce(e.org_ref, ''), '/', 2), '')                               as org_id,

    -- context flags
    (k.encounter_ref is not null)                                as has_encounter_ref,
    (e.org_ref is not null)                                      as has_org_ref,
    (coalesce(k.author_ref, e.practitioner_ref) is not null)     as has_clinician_ref,

    -- time buckets (bucket starts + label)
    -- pick a reporting TZ once (configurable)
    -- {{ var('report_tz', 'UTC') }}

    -- Boundaries
    (authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::date                 AS qr_date,
    date_trunc('week',  authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::date  AS qr_week_start,   -- ISO week: Monday start
    date_trunc('month', authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::date  AS qr_month_start,

    -- Human label (ISO week-year safe)
    to_char(date_trunc('week', authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}'),
            'IYYY-"W"IW')                                                             AS qr_week_label,

    -- Numeric features (useful for GROUP BY / filters)
    extract(isoyear from authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::int AS qr_iso_year,
    extract(week    from authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::int AS qr_iso_week,
    extract(year    from authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::int AS qr_year,
    extract(month   from authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::int AS qr_month_num,

    -- lineage from Airbyte
    k.airbyte_raw_id,
    k.loaded_at                    -- _airbyte_extracted_at passthrough
  from qr_keys k
  left join enc e
    on k.encounter_ref = e.encounter_ref
  left join q_meta_url u
    on k.questionnaire_canonical_url = u.questionnaire_canonical_url
  left join q_meta_id i
    on k.questionnaire_logical_id = i.questionnaire_logical_id_meta
)

select
  b.*,
  case
    when b.encounter_id is not null
     and row_number() over (partition by b.encounter_id order by b.authored_ts desc) = 1
    then true else false
  end as is_latest_for_encounter
from base b
