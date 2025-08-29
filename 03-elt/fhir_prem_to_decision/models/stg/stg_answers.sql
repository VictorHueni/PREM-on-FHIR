{{ config(materialized='view') }}

WITH RECURSIVE

-- Top-level QR rows + a robust questionnaire_id
qrs AS (
  SELECT
    COALESCE(qr_id, (resource::jsonb->>'id'))                                  AS qr_id,
    authored_ts,
    questionnaire_ref,
    -- fall back to JSON if questionnaire_ref is null
    split_part(
      COALESCE(questionnaire_ref, resource::jsonb->>'questionnaire'),
      '/',
      2
    )                                                                          AS questionnaire_id,
    patient_ref,
    encounter_ref,
    author_ref,
    resource::jsonb                                                            AS resource_jsonb
  FROM {{ source('raw', 'questionnaireresponse_current') }}
),

-- Explode QR.item tree -> answers
item_tree AS (
  -- root items
  SELECT
    q.qr_id, q.authored_ts, q.questionnaire_id, q.patient_ref, q.encounter_ref, q.author_ref,
    (i->>'linkId')::text AS linkid,
    i                    AS item_node
  FROM qrs q
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(q.resource_jsonb->'item','[]'::jsonb)) AS i

  UNION ALL

  -- nested items
  SELECT
    it.qr_id, it.authored_ts, it.questionnaire_id, it.patient_ref, it.encounter_ref, it.author_ref,
    (i->>'linkId')::text AS linkid,
    i                    AS item_node
  FROM item_tree it
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(it.item_node->'item','[]'::jsonb)) AS i
),

answers AS (
  SELECT
    it.qr_id,
    it.authored_ts,
    it.questionnaire_id,
    it.patient_ref,
    it.encounter_ref,
    it.author_ref AS clinician_ref,
    it.linkid     AS item_linkid,
    ans,
    row_number() OVER (PARTITION BY it.qr_id, it.linkid ORDER BY 1) AS answer_ordinal
  FROM item_tree it
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(it.item_node->'answer','[]'::jsonb)) AS ans
),

-- CodeSystem concept → ordinal lookup (system+code → ordinal)
cs AS (
  SELECT
    (c.resource::jsonb->>'url')::text AS system,
    concept->>'code'                  AS code,
    concept->>'display'               AS display,
    COALESCE(
      (SELECT (p->>'valueDecimal')::numeric
         FROM jsonb_array_elements(COALESCE(concept->'property','[]'::jsonb)) p
        WHERE p->>'code' = 'ordinalValue' LIMIT 1),
      (SELECT (e->>'valueDecimal')::numeric
         FROM jsonb_array_elements(COALESCE(concept->'extension','[]'::jsonb)) e
        WHERE e->>'url' = 'http://hl7.org/fhir/StructureDefinition/ordinalValue' LIMIT 1)
    ) AS ordinal_value
  FROM {{ source('raw','codesystem_current') }} c
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE((c.resource::jsonb)->'concept','[]'::jsonb)) AS concept
),

base AS (
  SELECT
    a.qr_id,
    a.authored_ts,
    a.questionnaire_id,
    a.patient_ref,
    a.encounter_ref,
    a.clinician_ref,
    a.item_linkid,
    a.answer_ordinal,

    -- raw fields
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

    -- numeric scoring (Likert via ordinal; otherwise numeric/boolean)
    CASE
      WHEN cs.ordinal_value IS NOT NULL                                       THEN cs.ordinal_value
      WHEN a.ans ? 'valueInteger'                                             THEN (a.ans->>'valueInteger')::numeric
      WHEN a.ans ? 'valueDecimal'                                             THEN (a.ans->>'valueDecimal')::numeric
      WHEN a.ans ? 'valueBoolean'                                             THEN CASE a.ans->>'valueBoolean' WHEN 'true' THEN 1 ELSE 0 END
      WHEN a.ans ? 'valueQuantity'
           AND (a.ans->'valueQuantity'->>'value') ~ '^-?[0-9]+(\.[0-9]+)?$'   THEN (a.ans->'valueQuantity'->>'value')::numeric
      ELSE NULL
    END                                   AS numeric_value
  FROM answers a
  LEFT JOIN cs
    ON a.ans ? 'valueCoding'
   AND cs.system = (a.ans->'valueCoding'->>'system')
   AND cs.code   = (a.ans->'valueCoding'->>'code')
),

-- Item metadata (domain)
itm AS (
  SELECT
    questionnaire_id,
    linkid,
    domain_code_value   AS item_domain,
    domain_code_system  AS item_domain_system
  FROM {{ ref('stg_items') }}
),

-- Determine top & top-2 box per item from observed ordinals
ordinals AS (
  SELECT
    b.questionnaire_id,
    b.item_linkid,
    MAX(b.numeric_value) FILTER (WHERE b.answer_kind = 'coding') AS max_ordinal_observed
  FROM base b
  GROUP BY 1,2
)

SELECT
  b.qr_id,
  b.authored_ts,
  b.questionnaire_id,
  b.patient_ref,
  b.encounter_ref,
  b.clinician_ref,
  b.item_linkid,
  i.item_domain,
  i.item_domain_system,
  b.answer_ordinal,
  b.answer_kind,
  b.numeric_value,
  b.value_string,
  b.value_display,
  b.value_code,
  b.value_coding_system,

  CASE
    WHEN b.answer_kind = 'coding'
     AND o.max_ordinal_observed IS NOT NULL
     AND b.numeric_value = o.max_ordinal_observed THEN TRUE
    ELSE FALSE
  END AS answer_is_top_box,

  CASE
    WHEN b.answer_kind = 'coding'
     AND o.max_ordinal_observed IS NOT NULL
     AND b.numeric_value >= (o.max_ordinal_observed - 1) THEN TRUE
    ELSE FALSE
  END AS answer_is_top2_box

FROM base b
LEFT JOIN itm i
  ON i.questionnaire_id = b.questionnaire_id
 AND i.linkid           = b.item_linkid
LEFT JOIN ordinals o
  ON o.questionnaire_id = b.questionnaire_id
 AND o.item_linkid      = b.item_linkid
