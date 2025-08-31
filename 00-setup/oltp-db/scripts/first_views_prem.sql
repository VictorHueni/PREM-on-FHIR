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

CREATE OR REPLACE VIEW public.v_dim_questionnaire AS
SELECT
  c.res_id,
  c.logical_id                              AS questionnaire_id,  -- PK
  c.res_updated,

  -- Core identifiers
  c.res_jsonb->>'url'                       AS url,
  c.res_jsonb#>>'{identifier,0,system}'     AS identifier_system,
  c.res_jsonb#>>'{identifier,0,value}'      AS identifier_value,

  -- Metadata
  c.res_jsonb->>'version'                   AS version,
  c.res_jsonb->>'name'                      AS name,
  c.res_jsonb->>'title'                     AS title,
  c.res_jsonb->>'status'                    AS status,
  c.res_jsonb->>'publisher'                 AS publisher,
  c.res_jsonb->>'purpose'                   AS purpose,
  c.res_jsonb->>'copyright'                 AS copyright,
  c.res_jsonb->>'description'               AS description,
  c.res_jsonb->>'approvalDate'              AS approval_date,
  c.res_jsonb->>'date'                      AS authored_date,
  c.res_jsonb#>>'{effectivePeriod,start}'   AS effective_start,
  c.res_jsonb#>>'{effectivePeriod,end}'     AS effective_end,

  -- Use context (first entry)
  c.res_jsonb#>>'{useContext,0,code,code}'             AS usecontext_code,
  c.res_jsonb#>>'{useContext,0,code,system}'           AS usecontext_system,
  c.res_jsonb#>>'{useContext,0,valueCodeableConcept,text}' AS usecontext_text,

  -- Subject type (first)
  c.res_jsonb#>>'{subjectType,0}'            AS subject_type,

  -- Questionnaire coding (overall code list)
  c.res_jsonb#>>'{code,0,system}'            AS code_system,
  c.res_jsonb#>>'{code,0,code}'              AS code_value,
  c.res_jsonb#>>'{code,0,display}'           AS code_display,

  jsonb_array_length(c.res_jsonb->'item')    AS item_count,

  c.res_jsonb                               AS resource
FROM public.v_fhir_current_json c
WHERE c.res_type = 'Questionnaire';

CREATE OR REPLACE VIEW public.v_dim_questionnaire_item AS
SELECT
  c.logical_id                              AS questionnaire_id,
  (item->>'linkId')                         AS linkid,
  item->>'text'                             AS question_text,
  item->>'type'                             AS question_type,
  (item->>'required')::boolean              AS is_required,
  item->>'answerValueSet'                   AS answer_valueset,

  -- Item codes (up to two: item code + domain code)
  item#>>'{code,0,system}'                  AS item_code_system,
  item#>>'{code,0,code}'                    AS item_code_value,
  item#>>'{code,0,display}'                 AS item_code_display,
  item#>>'{code,1,system}'                  AS domain_code_system,
  item#>>'{code,1,code}'                    AS domain_code_value,
  item#>>'{code,1,display}'                 AS domain_code_display,

  item                                      AS item_json
FROM public.v_fhir_current_json c
CROSS JOIN LATERAL jsonb_array_elements(c.res_jsonb->'item') AS item
WHERE c.res_type = 'Questionnaire';





CREATE OR REPLACE VIEW public.v_dim_patient AS
SELECT
  c.res_id,
  c.logical_id                                   AS patient_id,            -- PK (logical id)
  c.res_updated,

  -- Core demographics
  c.res_jsonb->>'gender'                         AS gender,
  c.res_jsonb->>'birthDate'                      AS birth_date,
  -- Patient name (first official)
  c.res_jsonb#>>'{name,0,family}'                AS family_name,
  c.res_jsonb#>>'{name,0,given,0}'               AS given_name_1,
  c.res_jsonb#>>'{name,0,given,1}'               AS given_name_2,
  c.res_jsonb#>>'{name,0,prefix,0}'              AS name_prefix,
  CONCAT_WS(' ',
    c.res_jsonb#>>'{name,0,prefix,0}',
    c.res_jsonb#>>'{name,0,given,0}',
    c.res_jsonb#>>'{name,0,given,1}',
    c.res_jsonb#>>'{name,0,family}'
  )                                              AS name_full,

  -- Address (first)
  c.res_jsonb#>>'{address,0,line,0}'             AS address_line1,
  c.res_jsonb#>>'{address,0,line,1}'             AS address_line2,
  c.res_jsonb#>>'{address,0,city}'               AS address_city,
  c.res_jsonb#>>'{address,0,state}'              AS address_state,
  c.res_jsonb#>>'{address,0,postalCode}'         AS address_postal_code,
  c.res_jsonb#>>'{address,0,country}'            AS address_country,

  -- Geolocation (from extension on address[0])
  (c.res_jsonb#>>'{address,0,extension,0,extension,0,valueDecimal}')::numeric AS geo_latitude,
  (c.res_jsonb#>>'{address,0,extension,0,extension,1,valueDecimal}')::numeric AS geo_longitude,

  -- Telecom (first)
  c.res_jsonb#>>'{telecom,0,system}'             AS telecom_0_system,
  c.res_jsonb#>>'{telecom,0,use}'                AS telecom_0_use,
  c.res_jsonb#>>'{telecom,0,value}'              AS telecom_0_value,

  -- Marital status
  COALESCE(
    c.res_jsonb#>>'{maritalStatus,coding,0,code}',
    c.res_jsonb#>>'{maritalStatus,text}'
  )                                              AS marital_status,

  -- Preferred language (first)
  COALESCE(
    c.res_jsonb#>>'{communication,0,language,coding,0,code}',
    c.res_jsonb#>>'{communication,0,language,text}'
  )                                              AS language_code,
  c.res_jsonb#>>'{communication,0,language,coding,0,display}' AS language_display,

  -- US Core: Race
  c.res_jsonb#>>'{extension,0,extension,0,valueCoding,system}'  AS race_system,
  c.res_jsonb#>>'{extension,0,extension,0,valueCoding,code}'    AS race_code,
  c.res_jsonb#>>'{extension,0,extension,0,valueCoding,display}' AS race_display,
  c.res_jsonb#>>'{extension,0,extension,1,valueString}'         AS race_text,

  -- US Core: Ethnicity
  c.res_jsonb#>>'{extension,1,extension,0,valueCoding,system}'  AS ethnicity_system,
  c.res_jsonb#>>'{extension,1,extension,0,valueCoding,code}'    AS ethnicity_code,
  c.res_jsonb#>>'{extension,1,extension,0,valueCoding,display}' AS ethnicity_display,
  c.res_jsonb#>>'{extension,1,extension,1,valueString}'         AS ethnicity_text,

  -- Birth sex (US Core)
  c.res_jsonb#>>'{extension,3,valueCode}'        AS birth_sex_code,

  -- Birth place (if present)
  c.res_jsonb#>>'{extension,4,valueAddress,city}'    AS birth_place_city,
  c.res_jsonb#>>'{extension,4,valueAddress,state}'   AS birth_place_state,
  c.res_jsonb#>>'{extension,4,valueAddress,country}' AS birth_place_country,

  -- Synthea QALY/DALY (synthetic)
  (c.res_jsonb#>>'{extension,5,valueDecimal}')::numeric AS daly,
  (c.res_jsonb#>>'{extension,6,valueDecimal}')::numeric AS qaly,

  -- Identifiers (pull common ones if present)
  -- 0: synthea UUID, 1: MRN, 2: SSN, 3: DL, 4: Passport (Synthea order)
  c.res_jsonb#>>'{identifier,0,system}'          AS id0_system,
  c.res_jsonb#>>'{identifier,0,value}'           AS id0_value,
  c.res_jsonb#>>'{identifier,1,system}'          AS id1_system,
  c.res_jsonb#>>'{identifier,1,value}'           AS id1_value,
  c.res_jsonb#>>'{identifier,1,type,coding,0,code}'    AS id1_type_code,
  c.res_jsonb#>>'{identifier,1,type,coding,0,display}' AS id1_type_display,

  c.res_jsonb                                     AS resource
FROM public.v_fhir_current_json c
WHERE c.res_type = 'Patient';

-- Conditions (diagnoses)
CREATE OR REPLACE VIEW public.v_dim_condition AS
SELECT
  c.res_id,
  c.logical_id                                   AS condition_id,         -- PK
  c.res_updated,

  -- Links
  c.res_jsonb#>>'{subject,reference}'            AS patient_ref,          -- e.g., 'Patient/6da1...'
  c.res_jsonb#>>'{encounter,reference}'          AS encounter_ref,        -- e.g., 'Encounter/3719e1...'

  -- Timing
  (c.res_jsonb#>>'{onsetDateTime}')::timestamptz  AS onset_ts,
  (c.res_jsonb#>>'{recordedDate}')::timestamptz   AS recorded_ts,

  -- Clinical + verification status (prefer codes; fall back to display)
  COALESCE(
    c.res_jsonb#>>'{clinicalStatus,coding,0,code}',
    c.res_jsonb#>>'{clinicalStatus,coding,0,display}',
    c.res_jsonb#>>'{clinicalStatus,text}'
  )                                             AS clinical_status,
  COALESCE(
    c.res_jsonb#>>'{verificationStatus,coding,0,code}',
    c.res_jsonb#>>'{verificationStatus,coding,0,display}',
    c.res_jsonb#>>'{verificationStatus,text}'
  )                                             AS verification_status,

  -- Category (first)
  c.res_jsonb#>>'{category,0,coding,0,code}'    AS category_code,
  c.res_jsonb#>>'{category,0,coding,0,display}' AS category_display,

  -- Code (primary SNOMED row if present)
  c.res_jsonb#>>'{code,coding,0,system}'        AS code_system,
  c.res_jsonb#>>'{code,coding,0,code}'          AS code,
  c.res_jsonb#>>'{code,coding,0,display}'       AS code_display,
  c.res_jsonb#>>'{code,text}'                   AS condition_text,

  c.res_jsonb                                   AS resource
FROM public.v_fhir_current_json c
WHERE c.res_type = 'Condition';



-- Procedures (rehab interventions, surgeries, therapies)
CREATE OR REPLACE VIEW public.v_dim_procedure AS
SELECT
  c.res_id,
  c.logical_id                               AS procedure_id,  -- PK
  c.res_updated,

  -- Status
  c.res_jsonb->>'status'                     AS status,

  -- Coding
  c.res_jsonb#>>'{code,text}'                AS procedure_text,
  c.res_jsonb#>>'{code,coding,0,system}'     AS code_system,
  c.res_jsonb#>>'{code,coding,0,code}'       AS code_value,
  c.res_jsonb#>>'{code,coding,0,display}'    AS code_display,

  -- Patient + Encounter context
  c.res_jsonb#>>'{subject,reference}'        AS patient_ref,
  c.res_jsonb#>>'{encounter,reference}'      AS encounter_ref,

  -- Location (facility reference)
  c.res_jsonb#>>'{location,reference}'       AS location_ref,
  c.res_jsonb#>>'{location,display}'         AS location_display,

  -- Performed timestamps
  (c.res_jsonb#>>'{performedPeriod,start}')::timestamptz AS performed_start,
  (c.res_jsonb#>>'{performedPeriod,end}')::timestamptz   AS performed_end,

  -- Full JSON
  c.res_jsonb                                AS resource

FROM public.v_fhir_current_json c
WHERE c.res_type = 'Procedure';


-- Encounters (context of PREM completion)
CREATE OR REPLACE VIEW public.v_dim_encounter AS
SELECT
  c.res_id,
  c.logical_id                                      AS encounter_id,   -- PK
  c.res_updated,
  c.res_jsonb->>'status'                            AS status,

  /* type text: prefer human-readable text, then coding.display, then coding.code */
  COALESCE(
    c.res_jsonb#>>'{type,0,text}',
    c.res_jsonb#>>'{type,0,coding,0,display}',
    c.res_jsonb#>>'{type,0,coding,0,code}'
  )                                                 AS encounter_type,

  /* class code (e.g., AMB/EMER/IMP) */
  c.res_jsonb#>>'{class,code}'                      AS encounter_class,

  /* period */
  (c.res_jsonb#>>'{period,start}')::timestamptz     AS start_ts,
  (c.res_jsonb#>>'{period,end}')::timestamptz       AS end_ts,

  /* patient + org + location + primary practitioner (1st participant) */
  c.res_jsonb#>>'{subject,reference}'               AS patient_ref,
  c.res_jsonb#>>'{serviceProvider,reference}'       AS org_ref,
  c.res_jsonb#>>'{location,0,location,reference}'   AS location_ref,
  c.res_jsonb#>>'{participant,0,individual,reference}' AS practitioner_ref,

  c.res_jsonb                                       AS resource
FROM public.v_fhir_current_json c
WHERE c.res_type = 'Encounter';



-- Practitioner (clinicians)
CREATE OR REPLACE VIEW public.v_dim_practitioner AS
SELECT
  c.res_id,
  c.logical_id                                      AS practitioner_id,   -- PK
  c.res_updated,

  -- Demographics
  (c.res_jsonb->>'active')::boolean                 AS is_active,
  c.res_jsonb->>'gender'                            AS gender,

  -- Name (first official)
  c.res_jsonb#>>'{name,0,prefix,0}'                 AS name_prefix,
  c.res_jsonb#>>'{name,0,given,0}'                  AS given_name,
  c.res_jsonb#>>'{name,0,family}'                   AS family_name,
  concat_ws(' ', 
    c.res_jsonb#>>'{name,0,prefix,0}', 
    c.res_jsonb#>>'{name,0,given,0}', 
    c.res_jsonb#>>'{name,0,family}'
  )                                                 AS full_name,

  -- Address (first)
  c.res_jsonb#>>'{address,0,line,0}'                AS address_line1,
  c.res_jsonb#>>'{address,0,line,1}'                AS address_line2,
  c.res_jsonb#>>'{address,0,city}'                  AS address_city,
  c.res_jsonb#>>'{address,0,state}'                 AS address_state,
  c.res_jsonb#>>'{address,0,postalCode}'            AS address_postal_code,
  c.res_jsonb#>>'{address,0,country}'               AS address_country,

  -- Telecom (first)
  c.res_jsonb#>>'{telecom,0,system}'                AS telecom_system,
  c.res_jsonb#>>'{telecom,0,use}'                   AS telecom_use,
  c.res_jsonb#>>'{telecom,0,value}'                 AS telecom_value,

  -- Utilization extension (synthea-specific)
  (c.res_jsonb#>>'{extension,0,valueInteger}')::int AS utilization_encounters,

  -- Identifier (NPI or other)
  c.res_jsonb#>>'{identifier,0,system}'             AS identifier_system,
  c.res_jsonb#>>'{identifier,0,value}'              AS identifier_value,

  c.res_jsonb                                       AS resource
FROM public.v_fhir_current_json c
WHERE c.res_type = 'Practitioner';


-- Organization (facility, hospital, rehab center)
CREATE OR REPLACE VIEW public.v_dim_organization AS
SELECT
  c.res_id,
  c.logical_id                                    AS org_id,        -- PK
  c.res_updated,

  -- Core attributes
  c.res_jsonb->>'name'                            AS name,
  (c.res_jsonb->>'active')::boolean               AS is_active,

  -- Organization type
  c.res_jsonb#>>'{type,0,coding,0,code}'          AS type_code,
  c.res_jsonb#>>'{type,0,coding,0,system}'        AS type_system,
  c.res_jsonb#>>'{type,0,coding,0,display}'       AS type_display,
  c.res_jsonb#>>'{type,0,text}'                   AS type_text,

  -- Address (first)
  c.res_jsonb#>>'{address,0,line,0}'              AS address_line1,
  c.res_jsonb#>>'{address,0,line,1}'              AS address_line2,
  c.res_jsonb#>>'{address,0,city}'                AS address_city,
  c.res_jsonb#>>'{address,0,state}'               AS address_state,
  c.res_jsonb#>>'{address,0,postalCode}'          AS address_postal_code,
  c.res_jsonb#>>'{address,0,country}'             AS address_country,

  -- Telecom (first)
  c.res_jsonb#>>'{telecom,0,system}'              AS telecom_system,
  c.res_jsonb#>>'{telecom,0,value}'               AS telecom_value,

  -- Utilization extensions (synthea-specific)
  (c.res_jsonb#>>'{extension,0,valueInteger}')::int AS utilization_encounters,
  (c.res_jsonb#>>'{extension,1,valueInteger}')::int AS utilization_procedures,
  (c.res_jsonb#>>'{extension,2,valueInteger}')::int AS utilization_labs,
  (c.res_jsonb#>>'{extension,3,valueInteger}')::int AS utilization_prescriptions,

  -- Identifier (first)
  c.res_jsonb#>>'{identifier,0,system}'           AS identifier_system,
  c.res_jsonb#>>'{identifier,0,value}'            AS identifier_value,

  c.res_jsonb                                     AS resource
FROM public.v_fhir_current_json c
WHERE c.res_type = 'Organization';



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

-- 2) CodeSystem lookup (system+code -> display, ordinal), DISTINCT per (system,code)
cs_raw AS (
  SELECT
    (v.res_text_vc::jsonb)->>'url' AS system,
    concept->>'code'               AS code,
    concept->>'display'            AS display,
    COALESCE(
      (SELECT (p->>'valueDecimal')::numeric
         FROM jsonb_array_elements(COALESCE(concept->'property','[]'::jsonb)) p
        WHERE p->>'code' = 'ordinalValue' LIMIT 1),
      (SELECT (e->>'valueDecimal')::numeric
         FROM jsonb_array_elements(COALESCE(concept->'extension','[]'::jsonb)) e
        WHERE e->>'url' = 'http://hl7.org/fhir/StructureDefinition/ordinalValue' LIMIT 1)
    ) AS ordinal_value
  FROM public.hfj_resource r
  JOIN public.hfj_res_ver v
    ON v.res_id = r.res_id
   AND v.res_ver = r.res_ver
  CROSS JOIN LATERAL jsonb_array_elements( (v.res_text_vc::jsonb)->'concept' ) AS concept
  WHERE r.res_type = 'CodeSystem'
    AND v.res_encoding = 'JSON'
    AND v.res_text_vc IS NOT NULL
),

cs AS (
  SELECT DISTINCT ON (system, code)
         system, code, display, ordinal_value
  FROM cs_raw
  WHERE system IS NOT NULL AND code IS NOT NULL
  ORDER BY system, code, display NULLS LAST
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
    -- Deterministic ordering: prefer coding → string → numeric → boolean → datetime → date → time → quantity
    row_number() OVER (
      PARTITION BY it.qr_id, it.linkid
      ORDER BY
        (ans->'valueCoding'->>'system') NULLS LAST,
        (ans->'valueCoding'->>'code')   NULLS LAST,
        (ans->>'valueString')           NULLS LAST,
        (ans->>'valueInteger')          NULLS LAST,
        (ans->>'valueDecimal')          NULLS LAST,
        (ans->>'valueBoolean')          NULLS LAST,
        (ans->>'valueDateTime')         NULLS LAST,
        (ans->>'valueDate')             NULLS LAST,
        (ans->>'valueTime')             NULLS LAST,
        (ans->'valueQuantity'->>'value') NULLS LAST,
        (ans->'valueQuantity'->>'unit')  NULLS LAST
    ) AS answer_ordinal
  FROM item_tree it
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(it.item_node->'answer','[]'::jsonb)) AS ans
)

SELECT
  -- Surrogate PK at (QR × item × answer)
  md5(
    coalesce(a.qr_id,'') || '|' ||
    coalesce(a.item_linkid,'') || '|' ||
    coalesce(a.answer_ordinal::text,'')
  )                                   AS pk_qr_answer,

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

  -- Answer projections (all common FHIR types)
  a.ans->>'valueString'                 AS value_string,
  (a.ans->>'valueInteger')::int         AS value_integer,
  (a.ans->>'valueDecimal')::numeric     AS value_decimal,
  (a.ans->>'valueBoolean')::boolean     AS value_boolean,
  a.ans->>'valueDateTime'               AS value_datetime,
  a.ans->>'valueDate'                   AS value_date,
  a.ans->>'valueTime'                   AS value_time,
  a.ans->'valueQuantity'->>'value'      AS value_quantity,
  a.ans->'valueQuantity'->>'unit'       AS value_quantity_unit,
  a.ans->'valueCoding'->>'system'       AS value_coding_system,
  a.ans->'valueCoding'->>'code'         AS value_code,
  COALESCE(
    a.ans->'valueCoding'->>'display',
    cs.display
  )                                     AS value_display,

  -- Kind + numeric value (for scoring/aggregation)
  CASE
    WHEN a.ans ? 'valueCoding'   THEN 'coding'
    WHEN a.ans ? 'valueString'   THEN 'string'
    WHEN a.ans ? 'valueInteger'  THEN 'integer'
    WHEN a.ans ? 'valueDecimal'  THEN 'decimal'
    WHEN a.ans ? 'valueBoolean'  THEN 'boolean'
    WHEN a.ans ? 'valueDateTime' THEN 'datetime'
    WHEN a.ans ? 'valueDate'     THEN 'date'
    WHEN a.ans ? 'valueTime'     THEN 'time'
    WHEN a.ans ? 'valueQuantity' THEN 'quantity'
    ELSE 'other'
  END                                   AS answer_kind,

  CASE
    WHEN cs.ordinal_value IS NOT NULL                     THEN cs.ordinal_value
    WHEN a.ans ? 'valueInteger'                           THEN (a.ans->>'valueInteger')::numeric
    WHEN a.ans ? 'valueDecimal'                           THEN (a.ans->>'valueDecimal')::numeric
    WHEN a.ans ? 'valueBoolean'                           THEN CASE (a.ans->>'valueBoolean') WHEN 'true' THEN 1 ELSE 0 END
    WHEN a.ans ? 'valueQuantity' AND (a.ans->'valueQuantity'->>'value') ~ '^-?[0-9]+(\.[0-9]+)?$'
                                                          THEN (a.ans->'valueQuantity'->>'value')::numeric
    ELSE NULL
  END                                   AS numeric_value,

  -- Raw JSON for lineage/debug
  a.ans                                   AS answer_json

FROM answers a
LEFT JOIN cs
  ON (a.ans ? 'valueCoding')
 AND cs.system = (a.ans->'valueCoding'->>'system')
 AND cs.code   = (a.ans->'valueCoding'->>'code')
ORDER BY a.qr_id, a.item_linkid, a.answer_ordinal;


CREATE OR REPLACE VIEW public.v_fact_prem_clinical AS
SELECT
  /* Stable surrogate PK at the grain: QR answer × Encounter × (optional Condition/Procedure) */
  md5(
    coalesce(qr.qr_id,'') || '|' ||
    coalesce(qr.item_linkid,'') || '|' ||
    coalesce(qr.answer_ordinal::text,'') || '|' ||
    coalesce(e.encounter_id,'') || '|' ||
    coalesce(cond.condition_id,'') || '|' ||
    coalesce(proc.procedure_id,'')
  )                                        AS fact_row_id,

  /* QR answer grain */
  qr.qr_id,
  qr.authored_ts,
  qr.questionnaire_ref,
  qr.item_linkid,
  qi.question_text,
  qi.item_code_value                        AS item_code,
  qi.item_code_system                       AS item_code_system,
  qi.domain_code_value                      AS item_domain,
  qi.domain_code_system                     AS item_domain_system,
  qi.answer_valueset,
  qr.answer_kind,
  qr.numeric_value,
  qr.value_string,
  qr.value_display,

  /* Patient */
  p.patient_id,
  p.gender,
  p.birth_date,
  date_part('year', age(coalesce(e.start_ts, qr.authored_ts)::timestamp, (p.birth_date)::date))::int
                                            AS age_at_event_years,
  p.name_full                               AS patient_name,

  /* Encounter */
  e.encounter_id,
  e.encounter_type,
  e.encounter_class,
  e.start_ts                                 AS encounter_start,
  e.end_ts                                   AS encounter_end,

  /* Condition (prefer encounter-linked) */
  cond.condition_id,
  coalesce(cond.code_display, cond.condition_text) AS condition_text,
  cond.code_system,
  cond.code                                   AS condition_code,
  cond.category_code                           AS condition_category,
  cond.clinical_status,
  cond.verification_status,
  cond.onset_ts,
  cond.recorded_ts,

  /* Procedure (encounter-linked is best; may duplicate rows if multiple procedures) */
  proc.procedure_id,
  proc.procedure_text,
  proc.code_system       AS procedure_code_system,
  proc.code_value        AS procedure_code,
  proc.performed_start,
  proc.performed_end,

  /* Clinician: prefer QR.author; else Encounter.participant[0] */
  COALESCE(qr.clinician_ref, e.practitioner_ref) AS clinician_ref,
  prac.practitioner_id,
  prac.full_name          AS clinician_name,

  /* Organization via Encounter.serviceProvider */
  org.org_id,
  org.name                AS organization_name

FROM public.v_prem_qr_answers qr
/* Questionnaire item metadata (text + domain) */
LEFT JOIN public.v_dim_questionnaire_item qi
  ON qi.questionnaire_id = split_part(qr.questionnaire_ref, '/', 2)
 AND qi.linkid           = qr.item_linkid

/* Patient */
LEFT JOIN public.v_dim_patient p
  ON qr.patient_ref   = CONCAT('Patient/', p.patient_id)

/* Encounter */
LEFT JOIN public.v_dim_encounter e
  ON qr.encounter_ref = CONCAT('Encounter/', e.encounter_id)

/* Conditions: primarily those linked to the same encounter */
LEFT JOIN public.v_dim_condition cond
  ON cond.encounter_ref = qr.encounter_ref
 -- AND cond.patient_ref   = qr.patient_ref  -- (optional extra guard)

/* Procedures: those linked to the same encounter */
LEFT JOIN public.v_dim_procedure proc
  ON proc.encounter_ref = qr.encounter_ref

/* Clinician */
LEFT JOIN public.v_dim_practitioner prac
  ON COALESCE(qr.clinician_ref, e.practitioner_ref) = CONCAT('Practitioner/', prac.practitioner_id)

/* Organization from Encounter.serviceProvider */
LEFT JOIN public.v_dim_organization org
  ON e.org_ref = CONCAT('Organization/', org.org_id)

ORDER BY qr.qr_id, qr.item_linkid, qr.answer_ordinal;

GRANT SELECT ON public.v_fhir_current_json   TO airbyte_ro;
GRANT SELECT ON public.v_prem_qr_answers     TO airbyte_ro;
GRANT SELECT ON public.v_fact_prem_clinical  TO airbyte_ro;
GRANT SELECT ON public.v_dim_questionnaire       TO airbyte_ro;
GRANT SELECT ON public.v_dim_questionnaire_item  TO airbyte_ro;
GRANT SELECT ON public.v_dim_patient         TO airbyte_ro;
GRANT SELECT ON public.v_dim_condition       TO airbyte_ro;
GRANT SELECT ON public.v_dim_procedure       TO airbyte_ro;
GRANT SELECT ON public.v_dim_encounter       TO airbyte_ro;
GRANT SELECT ON public.v_dim_practitioner    TO airbyte_ro;
GRANT SELECT ON public.v_dim_organization    TO airbyte_ro;