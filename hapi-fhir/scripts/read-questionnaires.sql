-- Select Questionnaire header
WITH enc AS (
  SELECT e.res_id,
         COALESCE(fi.forced_id, e.res_id::text) AS enc_id
  FROM   hfj_resource e
  LEFT JOIN hfj_forced_id fi ON fi.resource_pid = e.res_id
  WHERE  e.res_type = 'Encounter' AND e.res_deleted_at IS NULL
),
enc_patient AS (
  -- Encounter.subject -> Patient
  SELECT l.src_resource_id AS enc_res_id, l.target_resource_id AS pat_res_id
  FROM   hfj_res_link l
  JOIN   hfj_resource r ON r.res_id = l.src_resource_id
  WHERE  r.res_type = 'Encounter'
    AND  l.target_resource_type = 'Patient'
    AND  l.src_path IN ('Encounter.subject','Encounter.patient')
),
pat AS (
  SELECT p.res_id,
         COALESCE(fp.forced_id, p.res_id::text) AS pat_id
  FROM   hfj_resource p
  LEFT JOIN hfj_forced_id fp ON fp.resource_pid = p.res_id
  WHERE  p.res_type = 'Patient' AND p.res_deleted_at IS NULL
),
enc_prac_one AS (
  -- choose one practitioner per encounter (deterministic)
  SELECT DISTINCT ON (l.src_resource_id)
         l.src_resource_id AS enc_res_id,
         l.target_resource_id AS prac_res_id
  FROM   hfj_res_link l
  JOIN   hfj_resource r ON r.res_id = l.src_resource_id
  WHERE  r.res_type = 'Encounter'
    AND  l.target_resource_type = 'Practitioner'
    AND  l.src_path = 'Encounter.participant.individual'
  ORDER BY l.src_resource_id, l.target_resource_id
),
prac AS (
  SELECT pr.res_id,
         COALESCE(fpr.forced_id, pr.res_id::text) AS prac_id
  FROM   hfj_resource pr
  LEFT JOIN hfj_forced_id fpr ON fpr.resource_pid = pr.res_id
  WHERE  pr.res_type = 'Practitioner' AND pr.res_deleted_at IS NULL
),
enc_date AS (
  SELECT d.res_id AS enc_res_id,
         d.sp_value_high AS period_end,
         d.sp_value_low  AS period_start
  FROM   hfj_spidx_date d
  JOIN   hfj_resource r ON r.res_id = d.res_id
  WHERE  r.res_type = 'Encounter' AND d.sp_name = 'date'
)
SELECT
  'Patient/'   || pat.pat_id AS patientId,
  'Encounter/' || enc.enc_id AS encounterId,
  CASE WHEN prac.prac_id IS NOT NULL
       THEN 'Practitioner/' || prac.prac_id
       ELSE NULL END        AS practitionerId,
  COALESCE(enc_date.period_end, enc_date.period_start, NOW()) AS authored,
  'Patient/' || pat.pat_id  AS src
FROM enc
JOIN enc_patient ON enc.res_id = enc_patient.enc_res_id
JOIN pat         ON pat.res_id = enc_patient.pat_res_id
LEFT JOIN enc_prac_one ep ON enc.res_id = ep.enc_res_id
LEFT JOIN prac          ON prac.res_id = ep.prac_res_id
LEFT JOIN enc_date      ON enc.res_id = enc_date.enc_res_id
ORDER BY patientId, encounterId;



-- Dimension: NREQ Likert scale codes
-- Dimension: Likert scale codes
WITH cs AS (
    SELECT v.res_text_vc::jsonb AS j
    FROM hfj_resource r
    JOIN hfj_res_ver v 
      ON v.res_id = r.res_id 
     AND v.res_ver = r.res_ver
    WHERE r.res_type = 'CodeSystem'
      AND v.res_text_vc::jsonb ->> 'url' = 'http://example.org/fhir/CodeSystem/nreq-likert-3'
    LIMIT 1
)
SELECT 
  j->>'url'               AS url,          -- CodeSystem root URL
  c->>'code'              AS likert_code,  -- "agree", "neutral", "disagree"
  c->>'display'           AS likert_label, -- "Mostly agree", ...
  (p->>'valueDecimal')::int AS ordinal_value
FROM cs,
     LATERAL jsonb_array_elements(j->'concept') AS c
LEFT JOIN LATERAL jsonb_array_elements(c->'property') AS p
       ON p->>'code' = 'ordinalValue'
ORDER BY ordinal_value DESC;

-- Dimension: NREQ Questionnaires Items (TO BE CHANGE TO GET ALL )
WITH q AS (
  SELECT v.res_text_vc::jsonb AS j
  FROM hfj_resource r
  JOIN hfj_res_ver v
    ON v.res_id = r.res_id
   AND v.res_ver = r.res_ver
  WHERE r.res_type = 'Questionnaire'
    AND v.res_text_vc::jsonb ->> 'url' = 'http://example.org/fhir/Questionnaire/NREQ'
  LIMIT 1
),
items AS (
  SELECT
    q.j->>'url'                               AS questionnaire_url,
    q.j->>'version'                           AS questionnaire_version,
    (q.j->'identifier'->0->>'value')          AS questionnaire_identifier, -- "NREQ-17-v1" if present
    itm                                        AS item_json,
    itm->>'linkId'                             AS link_id,
    itm->>'text'                               AS item_text,
    itm->>'type'                               AS item_type,
    itm->>'answerValueSet'                     AS answer_valueset,
    itm->'code'                                AS codes
  FROM q
  CROSS JOIN LATERAL jsonb_array_elements(q.j->'item') AS itm
),
vs AS (
  SELECT 
    v.res_text_vc::jsonb ->> 'url' AS valueset_url,
    jsonb_array_elements(v.res_text_vc::jsonb -> 'compose' -> 'include') ->> 'system' AS codesystem_url
  FROM hfj_resource r
  JOIN hfj_res_ver v
    ON v.res_id = r.res_id AND v.res_ver = r.res_ver
  WHERE r.res_type = 'ValueSet'
)
SELECT
  questionnaire_url,
  questionnaire_version,
  questionnaire_identifier,
  link_id,
  item_text AS questionnaire_text,
  item_type,
  answer_valueset,
  -- pivot the codes in one pass
  MAX(c->>'code') FILTER (WHERE c->>'system' = 'http://example.org/fhir/CodeSystem/nreq-items')
    AS nreq_code,
  MAX(c->>'code') FILTER (WHERE c->>'system' = 'http://example.org/fhir/CodeSystem/prem-paris-domain')
    AS paris_domain_code,
  -- now resolved dynamically from ValueSet → CodeSystem
  vs.codesystem_url AS codesystem_fk
FROM items
LEFT JOIN LATERAL jsonb_array_elements(coalesce(items.codes, '[]'::jsonb)) AS c ON TRUE
LEFT JOIN vs
  ON vs.valueset_url = items.answer_valueset
WHERE item_type IN ('choice','string','text','integer','boolean','decimal','date','dateTime','time')
GROUP BY
  questionnaire_url, questionnaire_version, questionnaire_identifier,
  link_id, questionnaire_text, item_type, answer_valueset, vs.codesystem_url
ORDER BY
  (regexp_replace(link_id, '\D','','g'))::int





-- FACT: QuestionnaireResponse Answers (generic for coding + string)

WITH qr AS (
  SELECT
    r.res_id,
    r.fhir_id,
    rv.res_text_vc::jsonb AS res
  FROM hfj_resource r
  JOIN hfj_res_ver rv ON rv.res_id = r.res_id
  WHERE r.res_type = 'QuestionnaireResponse'
    AND r.res_deleted_at IS NULL
    AND rv.res_ver = r.res_ver
    -- Optional: restrict to one questionnaire (e.g., PPNQ)
    -- AND rv.res_text_vc::jsonb->>'questionnaire' = 'http://example.org/fhir/Questionnaire/NeuroRehabPREM'
),

-- CodeSystem lookup (system + code -> display, ordinal_value)
cs AS (
  SELECT
    rv.res_text_vc::jsonb->>'url'  AS system,
    c->>'code'                     AS code,
    c->>'display'                  AS display,
    COALESCE(prop.ord, ext.ord)    AS ordinal_value
  FROM hfj_resource r
  JOIN hfj_res_ver rv ON rv.res_id = r.res_id
  CROSS JOIN LATERAL jsonb_array_elements(rv.res_text_vc::jsonb->'concept') AS c
  -- property-based ordinal (concept.property[] with code="ordinalValue")
  LEFT JOIN LATERAL (
    SELECT (p->>'valueDecimal')::numeric AS ord
    FROM jsonb_array_elements(COALESCE(c->'property','[]'::jsonb)) AS p
    WHERE p->>'code' = 'ordinalValue'
    LIMIT 1
  ) prop ON TRUE
  -- extension-based ordinal (concept.extension[] with url=".../ordinalValue")
  LEFT JOIN LATERAL (
    SELECT (e->>'valueDecimal')::numeric AS ord
    FROM jsonb_array_elements(COALESCE(c->'extension','[]'::jsonb)) AS e
    WHERE e->>'url' = 'http://hl7.org/fhir/StructureDefinition/ordinalValue'
    LIMIT 1
  ) ext ON TRUE
  WHERE r.res_type = 'CodeSystem'
    AND rv.res_ver = r.res_ver
),

-- Unnest QR items and answers (long grain: one row per answer occurrence)
qa AS (
  SELECT
    r.fhir_id                                  AS response_id,
    (res->>'authored')::timestamptz            AS authored_ts,
    res#>>'{subject,reference}'                AS patient_ref,
    res#>>'{encounter,reference}'              AS encounter_ref,
    res#>>'{author,reference}'                 AS clinician_ref,
    res->>'questionnaire'                      AS questionnaire_ref,
    item->>'linkId'                            AS question_id,
    a                                          AS answer_json
  FROM qr r
  CROSS JOIN LATERAL jsonb_array_elements(res->'item')          AS item
  CROSS JOIN LATERAL jsonb_array_elements(item->'answer')       AS a
)

SELECT
  -- Keys / context
  response_id,
  authored_ts,
  patient_ref,
  encounter_ref,
  clinician_ref,
  questionnaire_ref,
  question_id,

  -- Coding fields (for Likert/NPS/etc.)
  (answer_json->'valueCoding'->>'system')                AS answer_system,
  (answer_json->'valueCoding'->>'code')                  AS answer_code,
  COALESCE(
    (answer_json->'valueCoding'->>'display'),
    cs.display
  )                                                      AS answer_display,
  cs.ordinal_value                                       AS ordinal_value,

  -- Free-text (PPNQ q1..q8 + q9-text)
  (answer_json->>'valueString')                          AS answer_text,

  -- What type of answer did we get?
  CASE
    WHEN answer_json ? 'valueCoding'  THEN 'coding'
    WHEN answer_json ? 'valueString'  THEN 'string'
    WHEN answer_json ? 'valueInteger' THEN 'integer'
    WHEN answer_json ? 'valueDecimal' THEN 'decimal'
    WHEN answer_json ? 'valueBoolean' THEN 'boolean'
    WHEN answer_json ? 'valueDate'    THEN 'date'
    WHEN answer_json ? 'valueTime'    THEN 'time'
    ELSE 'other'
  END                                                    AS answer_kind,

  -- Generic numeric measure (prefers ordinal; falls back to numeric primitives)
  CASE
    WHEN cs.ordinal_value IS NOT NULL THEN cs.ordinal_value
    WHEN answer_json ? 'valueInteger' THEN (answer_json->>'valueInteger')::numeric
    WHEN answer_json ? 'valueDecimal' THEN (answer_json->>'valueDecimal')::numeric
    WHEN answer_json ? 'valueBoolean' THEN CASE (answer_json->>'valueBoolean') WHEN 'true' THEN 1 ELSE 0 END
    ELSE NULL
  END AS numeric_value

FROM qa
LEFT JOIN cs
  ON cs.system = (answer_json->'valueCoding'->>'system')
 AND cs.code   = (answer_json->'valueCoding'->>'code');
