{{ config(materialized='view') }}


WITH src AS (
  SELECT
    org_id,
    resource::jsonb AS resource_jsonb
  FROM {{ source('raw','organization_current') }}
)

SELECT
  COALESCE(s.org_id, s.resource_jsonb->>'id')      AS org_id,
  s.resource_jsonb->>'name'                         AS name,
  (s.resource_jsonb->>'active')::boolean            AS is_active
FROM src s