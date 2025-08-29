{{ config(materialized='view') }}

WITH src AS (
  SELECT
    encounter_id,
    patient_ref,
    org_ref,
    practitioner_ref,
    start_ts,
    end_ts,
    status,
    resource::jsonb AS resource_jsonb
  FROM {{ source('raw','encounter_current') }}
)

SELECT
  s.encounter_id,
  s.patient_ref,
  s.org_ref,
  COALESCE(
    s.practitioner_ref,
    s.resource_jsonb#>>'{participant,0,individual,reference}'
  )                                   AS practitioner_ref,
  s.start_ts,
  s.end_ts,
  s.status,
  COALESCE(
    s.resource_jsonb#>>'{type,0,text}',
    s.resource_jsonb#>>'{type,0,coding,0,display}',
    s.resource_jsonb#>>'{type,0,coding,0,code}'
  )                                   AS encounter_type,
  s.resource_jsonb#>>'{class,code}'   AS encounter_class
FROM src s
