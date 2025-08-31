-- =========================
-- HAPI OLTP: Minimal export views for Airbyte
-- =========================
-- All current (non-deleted) resources with parsed JSON
CREATE OR REPLACE VIEW public.v_fhir_current_json AS
SELECT
  r.res_id::bigint                          AS res_id,
  r.res_type                                AS res_type,
  r.res_ver                                 AS res_ver,
  r.res_updated                             AS res_updated,
  r.res_published                           AS res_published,
  r.res_deleted_at                          AS res_deleted_at,
  r.fhir_id                                 AS logical_id,  -- FHIR logical id
  v.res_encoding                            AS res_encoding,
  v.res_text_vc::jsonb                      AS res_jsonb
FROM public.hfj_resource r
JOIN public.hfj_res_ver v
  ON v.res_id = r.res_id
 AND v.res_ver = r.res_ver
WHERE r.res_deleted_at IS NULL
  AND v.res_encoding = 'JSON'
  AND v.res_text_vc IS NOT NULL;


CREATE OR REPLACE VIEW airbyte_export.resource_current AS
SELECT
  c.logical_id,
  c.res_type,
  c.res_updated    AS last_updated,
  c.res_published  AS first_seen,
  c.res_jsonb      AS resource
FROM public.v_fhir_current_json c;

-- ========== Per-resource thin views ==========
-- NOTE: Only simple #>> / ->> extractions (cheap).
-- No lateral jsonb_array_elements, no recursion, no joins.

-- Patient
CREATE OR REPLACE VIEW airbyte_export.patient_current AS
SELECT
  c.logical_id           AS patient_id,
  c.last_updated,
  c.first_seen,
  c.resource             AS resource
FROM airbyte_export.resource_current c
WHERE c.res_type = 'Patient';

-- Encounter
CREATE OR REPLACE VIEW airbyte_export.encounter_current AS
SELECT
  c.logical_id           AS encounter_id,
  c.last_updated,
  c.first_seen,
  c.resource#>>'{subject,reference}'                AS patient_ref,
  c.resource#>>'{serviceProvider,reference}'        AS org_ref,
  c.resource#>>'{participant,0,individual,reference}' AS practitioner_ref,
  (c.resource#>>'{period,start}')::timestamptz      AS start_ts,
  (c.resource#>>'{period,end}')::timestamptz        AS end_ts,
  c.resource->>'status'                             AS status,
  c.resource                                        AS resource
FROM airbyte_export.resource_current c
WHERE c.res_type = 'Encounter';

-- Condition
CREATE OR REPLACE VIEW airbyte_export.condition_current AS
SELECT
  c.logical_id           AS condition_id,
  c.last_updated,
  c.first_seen,
  c.resource#>>'{subject,reference}'   AS patient_ref,
  c.resource#>>'{encounter,reference}' AS encounter_ref,
  (c.resource#>>'{onsetDateTime}')::timestamptz    AS onset_ts,
  (c.resource#>>'{recordedDate}')::timestamptz     AS recorded_ts,
  c.resource                                       AS resource
FROM airbyte_export.resource_current c
WHERE c.res_type = 'Condition';

-- Procedure
CREATE OR REPLACE VIEW airbyte_export.procedure_current AS
SELECT
  c.logical_id           AS procedure_id,
  c.last_updated,
  c.first_seen,
  c.resource#>>'{subject,reference}'        AS patient_ref,
  c.resource#>>'{encounter,reference}'      AS encounter_ref,
  c.resource#>>'{location,reference}'       AS location_ref,
  (c.resource#>>'{performedPeriod,start}')::timestamptz AS performed_start,
  (c.resource#>>'{performedPeriod,end}')::timestamptz   AS performed_end,
  c.resource                                       AS resource
FROM airbyte_export.resource_current c
WHERE c.res_type = 'Procedure';

-- Practitioner
CREATE OR REPLACE VIEW airbyte_export.practitioner_current AS
SELECT
  c.logical_id           AS practitioner_id,
  c.last_updated,
  c.first_seen,
  c.resource             AS resource
FROM airbyte_export.resource_current c
WHERE c.res_type = 'Practitioner';

-- Organization
CREATE OR REPLACE VIEW airbyte_export.organization_current AS
SELECT
  c.logical_id           AS org_id,
  c.last_updated,
  c.first_seen,
  c.resource             AS resource
FROM airbyte_export.resource_current c
WHERE c.res_type = 'Organization';

-- Questionnaire
CREATE OR REPLACE VIEW airbyte_export.questionnaire_current AS
SELECT
  c.logical_id           AS questionnaire_id,
  c.last_updated,
  c.first_seen,
  c.resource->>'url'     AS url,
  c.resource             AS resource
FROM airbyte_export.resource_current c
WHERE c.res_type = 'Questionnaire';

-- QuestionnaireResponse (top-level only; do NOT explode items)
CREATE OR REPLACE VIEW airbyte_export.questionnaireresponse_current AS
SELECT
  c.logical_id           AS qr_id,
  c.last_updated,
  c.first_seen,
  c.resource->>'questionnaire'            AS questionnaire_ref,
  c.resource#>>'{subject,reference}'      AS patient_ref,
  c.resource#>>'{encounter,reference}'    AS encounter_ref,
  c.resource#>>'{author,reference}'       AS author_ref,
  (c.resource->>'authored')::timestamptz  AS authored_ts,
  c.resource                              AS resource
FROM airbyte_export.resource_current c
WHERE c.res_type = 'QuestionnaireResponse';

-- (Optional) CodeSystem and ValueSet (no concept expansion)
CREATE OR REPLACE VIEW airbyte_export.codesystem_current AS
SELECT
  c.logical_id           AS codesystem_id,
  c.last_updated,
  c.first_seen,
  c.resource->>'url'     AS url,
  c.resource             AS resource
FROM airbyte_export.resource_current c
WHERE c.res_type = 'CodeSystem';

CREATE OR REPLACE VIEW airbyte_export.valueset_current AS
SELECT
  c.logical_id           AS valueset_id,
  c.last_updated,
  c.first_seen,
  c.resource->>'url'     AS url,
  c.resource             AS resource
FROM airbyte_export.resource_current c
WHERE c.res_type = 'ValueSet';