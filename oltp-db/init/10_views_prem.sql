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


CREATE OR REPLACE VIEW public.v_prem_questionnaire AS
SELECT
  c.res_id,
  c.logical_id,
  c.res_updated,
  c.res_published,
  c.res_ver,
  c.res_jsonb->>'url'                     AS url,
  c.res_jsonb->>'version'                 AS version,
  c.res_jsonb->>'name'                    AS name,
  c.res_jsonb->>'title'                   AS title,
  c.res_jsonb->>'status'                  AS status,
  (c.res_jsonb->>'date')                  AS authored_date,
  c.res_jsonb->>'publisher'               AS publisher,
  jsonb_array_length(c.res_jsonb->'item') AS item_count,
  c.res_jsonb                             AS resource
FROM public.v_fhir_current_json c
WHERE c.res_type = 'Questionnaire';

CREATE OR REPLACE VIEW public.v_prem_questionnaire AS
SELECT
  c.res_id,
  c.logical_id,
  c.res_updated,
  c.res_published,
  c.res_ver,
  c.res_jsonb->>'url'                     AS url,
  c.res_jsonb->>'version'                 AS version,
  c.res_jsonb->>'name'                    AS name,
  c.res_jsonb->>'title'                   AS title,
  c.res_jsonb->>'status'                  AS status,
  (c.res_jsonb->>'date')                  AS authored_date,
  c.res_jsonb->>'publisher'               AS publisher,
  jsonb_array_length(c.res_jsonb->'item') AS item_count,
  c.res_jsonb                             AS resource
FROM public.v_fhir_current_json c
WHERE c.res_type = 'Questionnaire';

CREATE OR REPLACE VIEW public.v_prem_qr_answers AS
WITH RECURSIVE
-- 1) Current QuestionnaireResponses (+ context)
qr AS (
  SELECT
    c.res_id,
    c.logical_id AS qr_id,
    c.res_updated,
    c.res_jsonb,
    (c.res_jsonb->>'authored')::timestamptz        AS authored_ts,
    c.res_jsonb->>'questionnaire'                  AS questionnaire_ref,
    c.res_jsonb#>>'{subject,reference}'            AS patient_ref,
    c.res_jsonb#>>'{encounter,reference}'          AS encounter_ref,
    c.res_jsonb#>>'{author,reference}'             AS clinician_ref
  FROM public.v_fhir_current_json c
  WHERE c.res_type = 'QuestionnaireResponse'
),

-- 2) CodeSystem lookup (system+code -> display, ordinal)
cs AS (
  SELECT
    (v.res_text_vc::jsonb)->>'url'                        AS system,
    concept->>'code'                                      AS code,
    concept->>'display'                                   AS display,
    COALESCE(
      -- concept.property[] with code="ordinalValue"
      (
        SELECT (p->>'valueDecimal')::numeric
        FROM jsonb_array_elements(COALESCE(concept->'property','[]'::jsonb)) AS p
        WHERE p->>'code' = 'ordinalValue'
        LIMIT 1
      ),
      -- concept.extension[] with url=".../ordinalValue"
      (
        SELECT (e->>'valueDecimal')::numeric
        FROM jsonb_array_elements(COALESCE(concept->'extension','[]'::jsonb)) AS e
        WHERE e->>'url' = 'http://hl7.org/fhir/StructureDefinition/ordinalValue'
        LIMIT 1
      )
    )                                                     AS ordinal_value
  FROM public.hfj_resource r
  JOIN public.hfj_res_ver v
    ON v.res_id = r.res_id
   AND v.res_ver = r.res_ver
  CROSS JOIN LATERAL jsonb_array_elements( (v.res_text_vc::jsonb)->'concept' ) AS concept
  WHERE r.res_type = 'CodeSystem'
    AND v.res_encoding = 'JSON'
    AND v.res_text_vc IS NOT NULL
),

-- 3) Walk item tree recursively and explode answers
item_tree AS (
  -- top-level items
  SELECT
    q.res_id,
    q.qr_id,
    q.res_updated,
    q.authored_ts,
    q.questionnaire_ref,
    q.patient_ref,
    q.encounter_ref,
    q.clinician_ref,
    (elem->>'linkId')     AS linkid,
    elem                  AS item_node
  FROM qr q
  CROSS JOIN LATERAL jsonb_array_elements(q.res_jsonb->'item') AS elem

  UNION ALL

  -- nested items (if any)
  SELECT
    it.res_id,
    it.qr_id,
    it.res_updated,
    it.authored_ts,
    it.questionnaire_ref,
    it.patient_ref,
    it.encounter_ref,
    it.clinician_ref,
    (elem->>'linkId')     AS linkid,
    elem                  AS item_node
  FROM item_tree it
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(it.item_node->'item','[]'::jsonb)) AS elem
),

answers AS (
  SELECT
    it.res_id,
    it.qr_id,
    it.res_updated,
    it.authored_ts,
    it.questionnaire_ref,
    it.patient_ref,
    it.encounter_ref,
    it.clinician_ref,
    it.linkid AS item_linkid,
    ans,
    row_number() OVER (PARTITION BY it.qr_id, it.linkid ORDER BY 1) AS answer_ordinal
  FROM item_tree it
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(it.item_node->'answer','[]'::jsonb)) AS ans
)

SELECT
  -- Context / keys
  a.res_id,
  a.qr_id,
  a.res_updated,
  a.authored_ts,
  a.questionnaire_ref,
  a.patient_ref,
  a.encounter_ref,
  a.clinician_ref,
  a.item_linkid,
  a.answer_ordinal,

  -- Answer projections
  a.ans->>'valueString'                 AS value_string,
  (a.ans->>'valueInteger')::int         AS value_integer,
  (a.ans->>'valueDecimal')::numeric     AS value_decimal,
  (a.ans->>'valueBoolean')::boolean     AS value_boolean,
  a.ans->>'valueDateTime'               AS value_datetime,
  a.ans->>'valueDate'                   AS value_date,
  a.ans->'valueCoding'->>'system'       AS value_coding_system,
  a.ans->'valueCoding'->>'code'         AS value_code,
  COALESCE(
    a.ans->'valueCoding'->>'display',
    cs.display
  )                                     AS value_display,

  -- Kind + numeric value (for scoring/aggregation)
  CASE
    WHEN a.ans ? 'valueCoding'  THEN 'coding'
    WHEN a.ans ? 'valueString'  THEN 'string'
    WHEN a.ans ? 'valueInteger' THEN 'integer'
    WHEN a.ans ? 'valueDecimal' THEN 'decimal'
    WHEN a.ans ? 'valueBoolean' THEN 'boolean'
    WHEN a.ans ? 'valueDate'    THEN 'date'
    WHEN a.ans ? 'valueTime'    THEN 'time'
    ELSE 'other'
  END                                   AS answer_kind,

  CASE
    WHEN cs.ordinal_value IS NOT NULL               THEN cs.ordinal_value
    WHEN a.ans ? 'valueInteger'                     THEN (a.ans->>'valueInteger')::numeric
    WHEN a.ans ? 'valueDecimal'                     THEN (a.ans->>'valueDecimal')::numeric
    WHEN a.ans ? 'valueBoolean'                     THEN CASE (a.ans->>'valueBoolean') WHEN 'true' THEN 1 ELSE 0 END
    ELSE NULL
  END                                   AS numeric_value,

  -- Raw JSON for lineage/debug
  a.ans                                   AS answer_json

FROM answers a
LEFT JOIN cs
  ON cs.system = (a.ans->'valueCoding'->>'system')
 AND cs.code   = (a.ans->'valueCoding'->>'code')
ORDER BY a.qr_id, a.item_linkid, a.answer_ordinal;


CREATE OR REPLACE VIEW public.v_dim_patient AS
SELECT
  c.res_id,
  c.logical_id                        AS patient_id,
  c.res_updated,
  c.res_jsonb->>'gender'              AS gender,
  c.res_jsonb->>'birthDate'           AS birth_date,
  c.res_jsonb                         AS resource
FROM public.v_fhir_current_json c
WHERE c.res_type = 'Patient';

GRANT SELECT ON public.v_fhir_current_json TO airbyte_ro;
GRANT SELECT ON public.v_prem_questionnaire TO airbyte_ro;
GRANT SELECT ON public.v_prem_questionnaire TO airbyte_ro;
GRANT SELECT ON public.v_dim_patient TO airbyte_ro;