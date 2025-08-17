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
