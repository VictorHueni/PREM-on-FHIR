{{ config(materialized='view') }}

WITH src AS (
  SELECT
    patient_id,
    resource::jsonb AS resource_jsonb
  FROM {{ source('raw','patient_current') }}
),
base AS (
  SELECT
    COALESCE(s.patient_id, s.resource_jsonb->>'id')                 AS patient_id,
    s.resource_jsonb->>'gender'                                     AS gender,
    (s.resource_jsonb->>'birthDate')::date                          AS birth_date,
    concat_ws(' ',
      s.resource_jsonb#>>'{name,0,prefix,0}',
      s.resource_jsonb#>>'{name,0,given,0}',
      s.resource_jsonb#>>'{name,0,given,1}',
      s.resource_jsonb#>>'{name,0,family}'
    )                                                               AS name_full,
    s.resource_jsonb                                                AS resource_jsonb
  FROM src s
  WHERE COALESCE(s.patient_id, s.resource_jsonb->>'id') IS NOT NULL
)

SELECT
  /* keys & basics */
  b.patient_id,
  b.gender,
  b.birth_date,
  b.name_full,

  /* normalized + derived */
  CASE
    WHEN b.gender ILIKE 'male'   THEN 'male'
    WHEN b.gender ILIKE 'female' THEN 'female'
    WHEN b.gender ILIKE 'other'  OR b.gender ILIKE 'non%' THEN 'other'
    WHEN b.gender IS NULL OR b.gender IN ('', 'unknown','UNK') THEN 'unknown'
    ELSE 'unknown'
  END                                                AS gender_norm,

  EXTRACT(YEAR FROM b.birth_date)::int               AS birth_year,

  CASE WHEN b.birth_date IS NOT NULL
       THEN date_part(
              'year',
              age( (now() AT TIME ZONE '{{ var("report_tz","UTC") }}')::date
                , b.birth_date )
            )::int
  END                                                AS age_current,

  /* coarse age bands for dashboards */
  CASE
    WHEN b.birth_date IS NULL THEN NULL
    WHEN date_part('year', age(now(), b.birth_date)) < 18 THEN '0–17'
    WHEN date_part('year', age(now(), b.birth_date)) < 35 THEN '18–34'
    WHEN date_part('year', age(now(), b.birth_date)) < 50 THEN '35–49'
    WHEN date_part('year', age(now(), b.birth_date)) < 65 THEN '50–64'
    WHEN date_part('year', age(now(), b.birth_date)) < 80 THEN '65–79'
    ELSE '80+'
  END                                                AS age_band_current,

  /* activity / deceased */
  COALESCE( (b.resource_jsonb->>'active')::boolean, TRUE )  AS is_active,
  COALESCE( (b.resource_jsonb->>'deceasedBoolean')::boolean
          , (b.resource_jsonb ? 'deceasedDateTime') )       AS is_deceased,

  /* language (first) if present */
  COALESCE(
    b.resource_jsonb#>>'{communication,0,language,coding,0,code}',
    b.resource_jsonb#>>'{communication,0,language,text}'
  )                                                  AS language_code,
  b.resource_jsonb#>>'{communication,0,language,coding,0,display}'
                                                     AS language_display,

  /* phones – prefer mobile, else home, else work */
  (
    SELECT t->>'value'
    FROM jsonb_array_elements(COALESCE(b.resource_jsonb->'telecom','[]'::jsonb)) t
    WHERE t->>'system' = 'phone'
    ORDER BY CASE t->>'use'
              WHEN 'mobile' THEN 0
              WHEN 'home'   THEN 1
              WHEN 'work'   THEN 2
              ELSE 99
            END
    LIMIT 1
  )                                                  AS phone_primary,

  /* address (first) */
  b.resource_jsonb#>>'{address,0,line,0}'            AS address_line1,
  b.resource_jsonb#>>'{address,0,city}'              AS address_city,
  b.resource_jsonb#>>'{address,0,state}'             AS address_state,
  b.resource_jsonb#>>'{address,0,postalCode}'        AS address_postal_code,
  b.resource_jsonb#>>'{address,0,country}'           AS address_country,
  (
    b.resource_jsonb#>>'{address,0,line,0}' IS NOT NULL
    OR b.resource_jsonb#>>'{address,0,city}' IS NOT NULL
  )                                                  AS has_address,

  /* identifiers: MRN (if typed) + SSN last4 (masked) */
  (
    SELECT id->>'value'
    FROM jsonb_array_elements(COALESCE(b.resource_jsonb->'identifier','[]'::jsonb)) id
    WHERE id#>>'{type,coding,0,code}' = 'MR'
    LIMIT 1
  )                                                  AS id_mrn_value,
  (
    SELECT id->>'system'
    FROM jsonb_array_elements(COALESCE(b.resource_jsonb->'identifier','[]'::jsonb)) id
    WHERE id#>>'{type,coding,0,code}' = 'MR'
    LIMIT 1
  )                                                  AS id_mrn_system,
  (
    SELECT RIGHT(regexp_replace(id->>'value','[^0-9]','','g'),4)
    FROM jsonb_array_elements(COALESCE(b.resource_jsonb->'identifier','[]'::jsonb)) id
    WHERE (id->>'system') = 'http://hl7.org/fhir/sid/us-ssn'
    LIMIT 1
  )                                                  AS id_ssn_last4,

  /* privacy-ready pseudonym (configure salt in dbt_project.yml) */
  md5( COALESCE(b.patient_id,'') || '|' || '{{ var("patient_pseudonym_salt","dev-salt") }}' )
                                                     AS patient_pseudonym
FROM base b
