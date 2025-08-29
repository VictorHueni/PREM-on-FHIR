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
    )                                                               AS name_full
  FROM src s
  WHERE COALESCE(s.patient_id, s.resource_jsonb->>'id') IS NOT NULL
)

SELECT
  b.*,

  /* gender_norm: male | female | other | unknown */
  CASE
    WHEN b.gender ILIKE 'male'                        THEN 'male'
    WHEN b.gender ILIKE 'female'                      THEN 'female'
    WHEN b.gender ILIKE 'other'
       OR b.gender ILIKE 'non%'                       THEN 'other'
    WHEN b.gender IS NULL OR b.gender IN ('', 'unknown','UNK')
                                                     THEN 'unknown'
    ELSE 'unknown'
  END                                                AS gender_norm,

  EXTRACT(YEAR FROM b.birth_date)::int               AS birth_year,

  /* age today in your reporting TZ */
  CASE WHEN b.birth_date IS NOT NULL
       THEN date_part(
              'year',
              age( (now() AT TIME ZONE '{{ var("report_tz","UTC") }}')::date
                , b.birth_date )
            )::int
  END                                                AS age_current,

  /* lightweight pseudonymization (use a secret salt var) */
  md5( COALESCE(b.patient_id,'') || '|' || '{{ var("patient_pseudonym_salt","dev-salt") }}' )
                                                     AS patient_pseudonym
FROM base b
