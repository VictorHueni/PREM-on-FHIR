{{ config(materialized='view') }}

WITH qr AS (
  SELECT
    qr_id,
    authored_ts,
    questionnaire_ref,
    split_part(coalesce(questionnaire_ref,''), '/', 2) AS questionnaire_id,
    patient_ref,
    encounter_ref,
    author_ref
  FROM {{ source('raw', 'questionnaireresponse_current') }}
),
enc AS (
  SELECT
    encounter_id,
    'Encounter/' || encounter_id AS encounter_ref,
    org_ref,
    practitioner_ref
  FROM {{ source('raw', 'encounter_current') }}
)

SELECT
  q.qr_id,
  q.authored_ts,
  q.questionnaire_id,
  q.patient_ref,
  q.encounter_ref,
  COALESCE(q.author_ref, e.practitioner_ref) AS clinician_ref,
  e.org_ref                                   AS org_ref
FROM qr q
LEFT JOIN enc e
  ON q.encounter_ref = e.encounter_ref
