{{ config(materialized='view') }}

WITH qr AS (
  SELECT
    qr_id,
    authored_ts,
    -- prefer canonical URL in JSON; fall back to ref column
    COALESCE((resource::jsonb->>'questionnaire')::text, questionnaire_ref) AS questionnaire_any,
    patient_ref,
    encounter_ref,
    author_ref,

    -- Airbyte lineage
    _airbyte_raw_id        AS airbyte_raw_id,
    _airbyte_extracted_at  AS loaded_at,
    _airbyte_generation_id AS airbyte_generation_id,
    _airbyte_meta::jsonb   AS airbyte_meta
  FROM {{ source('raw','questionnaireresponse_current') }}
),

-- tease out URL vs logical id
qr_keys AS (
  SELECT
    q.*,
    CASE WHEN questionnaire_any ~* '^https?://'     THEN questionnaire_any END AS questionnaire_canonical_url,
    CASE WHEN questionnaire_any LIKE 'Questionnaire/%'
         THEN split_part(questionnaire_any,'/',2)
    END AS questionnaire_logical_id
  FROM qr q
),

-- Questionnaire metadata by canonical URL
q_meta_url AS (
  SELECT
    (resource::jsonb->>'url')::text    AS questionnaire_canonical_url,
    questionnaire_id                   AS questionnaire_logical_id_meta,
    (resource::jsonb->>'version')::text AS questionnaire_version_meta
  FROM {{ source('raw','questionnaire_current') }}
),

-- Fallback metadata by logical id
q_meta_id AS (
  SELECT
    questionnaire_id                   AS questionnaire_logical_id_meta,
    (resource::jsonb->>'url')::text    AS questionnaire_canonical_url_meta,
    (resource::jsonb->>'version')::text AS questionnaire_version_meta
  FROM {{ source('raw','questionnaire_current') }}
),

-- Encounter context (for org/practitioner backfill + clean ids)
enc AS (
  SELECT
    encounter_id,
    'Encounter/' || encounter_id AS encounter_ref,
    org_ref,
    practitioner_ref
  FROM {{ source('raw','encounter_current') }}
),

base AS (
  SELECT
    k.qr_id,
    k.authored_ts,

    -- Canonical URL (best available)
    COALESCE(k.questionnaire_canonical_url, i.questionnaire_canonical_url_meta) AS questionnaire_url,

    -- Version via URL first, then by logical id
    COALESCE(u.questionnaire_version_meta, i.questionnaire_version_meta) AS questionnaire_version,

    -- questionnaire_id: last segment of canonical URL (e.g., NREQ), else logical id
    COALESCE(
      CASE
        WHEN COALESCE(k.questionnaire_canonical_url, i.questionnaire_canonical_url_meta) IS NOT NULL
        THEN regexp_replace(COALESCE(k.questionnaire_canonical_url, i.questionnaire_canonical_url_meta), '^.*/', '')
      END,
      k.questionnaire_logical_id
    ) AS questionnaire_id,

    -- keep original refs
    k.patient_ref,
    k.encounter_ref,
    COALESCE(k.author_ref, e.practitioner_ref) AS clinician_ref,
    e.org_ref,

    -- clean ids (strip prefixes)
    NULLIF(split_part(COALESCE(k.patient_ref, ''), '/', 2), '')                          AS patient_id,
    NULLIF(split_part(COALESCE(k.encounter_ref, ''), '/', 2), '')                        AS encounter_id,
    NULLIF(split_part(COALESCE(COALESCE(k.author_ref, e.practitioner_ref), ''), '/', 2), '') AS clinician_id,
    NULLIF(split_part(COALESCE(e.org_ref, ''), '/', 2), '')                              AS org_id,

    -- context flags
    (k.encounter_ref IS NOT NULL)                            AS has_encounter_ref,
    (e.org_ref IS NOT NULL)                                  AS has_org_ref,
    (COALESCE(k.author_ref, e.practitioner_ref) IS NOT NULL) AS has_clinician_ref,

    -- time buckets (reporting TZ configurable)
    (authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::date AS qr_date,
    date_trunc('week',  authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::date  AS qr_week_start,   -- ISO week (Mon)
    date_trunc('month', authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::date  AS qr_month_start,
    to_char(date_trunc('week', authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}'), 'IYYY-"W"IW')      AS qr_week_label,

    -- numeric helpers
    EXTRACT(isoyear FROM authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::int AS qr_iso_year,
    EXTRACT(week    FROM authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::int AS qr_iso_week,
    EXTRACT(year    FROM authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::int AS qr_year,
    EXTRACT(month   FROM authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::int AS qr_month_num,

    -- lineage from Airbyte
    k.airbyte_raw_id,
    k.loaded_at
  FROM qr_keys k
  LEFT JOIN enc e
    ON k.encounter_ref = e.encounter_ref
  LEFT JOIN q_meta_url u
    ON k.questionnaire_canonical_url = u.questionnaire_canonical_url
  LEFT JOIN q_meta_id i
    ON k.questionnaire_logical_id = i.questionnaire_logical_id_meta
)

SELECT
  b.*,
  CASE
    WHEN b.encounter_id IS NOT NULL
     AND row_number() OVER (PARTITION BY b.encounter_id ORDER BY b.authored_ts DESC) = 1
    THEN TRUE ELSE FALSE
  END AS is_latest_for_encounter
FROM base b
