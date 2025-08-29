{{ config(materialized='view') }}


WITH src AS (
  SELECT
    practitioner_id,
    resource::jsonb AS resource_jsonb
  FROM {{ source('raw','practitioner_current') }}
)

SELECT
  COALESCE(s.practitioner_id, s.resource_jsonb->>'id') AS practitioner_id,
  s.resource_jsonb->>'gender'                           AS gender,
  concat_ws(' ',
    s.resource_jsonb#>>'{name,0,prefix,0}',
    s.resource_jsonb#>>'{name,0,given,0}',
    s.resource_jsonb#>>'{name,0,family}'
  )                                                     AS full_name
FROM src s
WHERE COALESCE(s.practitioner_id, s.resource_jsonb->>'id') IS NOT NULL