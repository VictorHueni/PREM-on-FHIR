{{ config(materialized='view') }}

WITH src AS (
  SELECT
    practitioner_id,
    resource::jsonb              AS resource_jsonb,
    _airbyte_extracted_at        AS loaded_at,
    _airbyte_meta::jsonb         AS airbyte_meta
  FROM {{ source('raw','practitioner_current') }}
),

base AS (
  SELECT
    /* stable key */
    COALESCE(s.practitioner_id, s.resource_jsonb->>'id')     AS practitioner_id,

    /* status + demographics */
    (s.resource_jsonb->>'active')::boolean                   AS is_active,
    s.resource_jsonb->>'gender'                               AS gender,

    /* names */
    s.resource_jsonb#>>'{name,0,prefix,0}'                   AS name_prefix,
    s.resource_jsonb#>>'{name,0,given,0}'                    AS given_name,
    s.resource_jsonb#>>'{name,0,family}'                     AS family_name,
    concat_ws(' ',
      s.resource_jsonb#>>'{name,0,prefix,0}',
      s.resource_jsonb#>>'{name,0,given,0}',
      s.resource_jsonb#>>'{name,0,family}'
    )                                                        AS full_name,

    /* contact: prefer work email/phone if present */
    (
      SELECT t->>'value'
      FROM jsonb_array_elements(COALESCE(s.resource_jsonb->'telecom','[]'::jsonb)) t
      WHERE t->>'system' = 'email'
      ORDER BY CASE t->>'use'
                WHEN 'work' THEN 0
                WHEN 'temp' THEN 1
                WHEN 'home' THEN 2
                WHEN 'old'  THEN 98
                ELSE 99
              END
      LIMIT 1
    )                                                        AS email_primary,
    (
      SELECT t->>'value'
      FROM jsonb_array_elements(COALESCE(s.resource_jsonb->'telecom','[]'::jsonb)) t
      WHERE t->>'system' = 'phone'
      ORDER BY CASE t->>'use'
                WHEN 'work' THEN 0
                WHEN 'mobile' THEN 1
                WHEN 'home' THEN 2
                WHEN 'old'  THEN 98
                ELSE 99
              END
      LIMIT 1
    )                                                        AS phone_primary,

    /* address (first) */
    s.resource_jsonb#>>'{address,0,line,0}'                  AS address_line1,
    s.resource_jsonb#>>'{address,0,city}'                    AS address_city,
    s.resource_jsonb#>>'{address,0,state}'                   AS address_state,
    s.resource_jsonb#>>'{address,0,postalCode}'              AS address_postal_code,
    s.resource_jsonb#>>'{address,0,country}'                 AS address_country,

    /* identifiers */
    s.resource_jsonb#>>'{identifier,0,system}'               AS identifier_system_first,
    s.resource_jsonb#>>'{identifier,0,value}'                AS identifier_value_first,
    (
      SELECT i->>'value'
      FROM jsonb_array_elements(COALESCE(s.resource_jsonb->'identifier','[]'::jsonb)) i
      WHERE i->>'system' ILIKE '%us-npi%'
      LIMIT 1
    )                                                        AS npi,

    /* qualification (if present) */
    s.resource_jsonb#>>'{qualification,0,code,coding,0,system}'  AS qual_code_system,
    s.resource_jsonb#>>'{qualification,0,code,coding,0,code}'    AS qual_code,
    s.resource_jsonb#>>'{qualification,0,code,coding,0,display}' AS qual_display,
    s.resource_jsonb#>>'{qualification,0,code,text}'             AS qual_text,

    s.loaded_at
  FROM src s
  WHERE COALESCE(s.practitioner_id, s.resource_jsonb->>'id') IS NOT NULL
)

SELECT
  b.*,

  /* normalized fields for robust slicing */
  CASE
    WHEN b.gender ILIKE 'male'   THEN 'male'
    WHEN b.gender ILIKE 'female' THEN 'female'
    WHEN b.gender ILIKE 'other' OR b.gender ILIKE 'non%' THEN 'other'
    WHEN b.gender IS NULL OR b.gender IN ('', 'unknown','UNK') THEN 'unknown'
    ELSE 'unknown'
  END                                                 AS gender_norm,

  /* simple helpers */
  NULLIF(trim(b.full_name),'')                        AS name_clean,
  split_part(COALESCE(b.email_primary,''), '@', 2)    AS email_domain,
  (b.address_line1 IS NOT NULL OR b.address_city IS NOT NULL) AS has_address,

  /* slug/pseudonym (for grouping/de-id in BI) */
  btrim(regexp_replace(lower(COALESCE(b.full_name,'')), '[^a-z0-9]+', '-', 'g'), '-') AS clinician_slug,
  md5( COALESCE(b.practitioner_id,'') || '|' || '{{ var("practitioner_pseudonym_salt","dev-salt") }}' )
                                                     AS clinician_pseudonym

FROM base b
