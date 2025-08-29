{{ config(materialized='view') }}

WITH src AS (
  SELECT
    patient_id,
    resource::jsonb AS resource_jsonb
  FROM {{ source('raw','patient_current') }}
)

SELECT
  COALESCE(s.patient_id, s.resource_jsonb->>'id')       AS patient_id,
  s.resource_jsonb->>'gender'                           AS gender,
  (s.resource_jsonb->>'birthDate')::date                AS birth_date,
  concat_ws(' ',
    s.resource_jsonb#>>'{name,0,prefix,0}',
    s.resource_jsonb#>>'{name,0,given,0}',
    s.resource_jsonb#>>'{name,0,given,1}',
    s.resource_jsonb#>>'{name,0,family}'
  )                                                     AS name_full
FROM src s
WHERE COALESCE(s.patient_id, s.resource_jsonb->>'id') IS NOT NULL