{{ config(materialized='view') }}

WITH RECURSIVE
src AS (
  SELECT
    questionnaire_id,
    resource::jsonb AS resource_jsonb
  FROM {{ source('raw', 'questionnaire_current') }}
),

/* ---------------------------------------------
   Walk the item tree with ordinality + hierarchy
   --------------------------------------------- */
item_tree AS (
  /* roots */
  SELECT
    s.questionnaire_id,
    NULL::text                                   AS parent_linkid,
    0::int                                        AS depth,
    ord::int                                      AS item_order,
    (ord::text)                                   AS path,
    (i->>'linkId')::text                          AS linkid,
    i                                             AS item_node
  FROM src s
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(s.resource_jsonb->'item','[]'::jsonb))
       WITH ORDINALITY AS t(i, ord)

  UNION ALL

  /* children */
  SELECT
    it.questionnaire_id,
    (it.item_node->>'linkId')::text               AS parent_linkid,
    it.depth + 1                                  AS depth,
    ord::int                                      AS item_order,
    (it.path || '.' || ord::text)                 AS path,
    (i->>'linkId')::text                          AS linkid,
    i                                             AS item_node
  FROM item_tree it
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(it.item_node->'item','[]'::jsonb))
       WITH ORDINALITY AS t(i, ord)
),

/* ---------------------------------------------
   Optional scale bounds from CodeSystems with
   ordinalValue (min/max per CodeSystem “key”)
   --------------------------------------------- */
cs_ord AS (
  SELECT
    /* last path segment of the CodeSystem URL, lowercased */
    lower(regexp_replace((c.resource::jsonb->>'url'), '^.*/', '')) AS cs_key,
    min(ord_val) AS likert_min,
    max(ord_val) AS likert_max
  FROM {{ source('raw','codesystem_current') }} c
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE((c.resource::jsonb)->'concept','[]'::jsonb)) AS concept
  CROSS JOIN LATERAL (
    SELECT COALESCE(
      (SELECT (p->>'valueDecimal')::numeric
         FROM jsonb_array_elements(COALESCE(concept->'property','[]'::jsonb)) p
        WHERE p->>'code' = 'ordinalValue' LIMIT 1),
      (SELECT (e->>'valueDecimal')::numeric
         FROM jsonb_array_elements(COALESCE(concept->'extension','[]'::jsonb)) e
        WHERE e->>'url' = 'http://hl7.org/fhir/StructureDefinition/ordinalValue' LIMIT 1)
    ) AS ord_val
  ) ov
  WHERE ord_val IS NOT NULL
  GROUP BY 1
)

SELECT DISTINCT
  it.questionnaire_id,
  it.linkid,

  /* hierarchy/context */
  it.parent_linkid,
  it.depth,
  it.path,
  it.item_order,

  /* core item fields */
  it.item_node->>'text'                                  AS question_text,
  it.item_node->>'type'                                  AS question_type,
  (it.item_node->>'required')::boolean                   AS is_required,
  (it.item_node->>'repeats')::boolean                    AS repeats,
  it.item_node->>'answerValueSet'                        AS answer_valueset,

  /* leaf detection: no children */
  COALESCE(jsonb_array_length(it.item_node->'item'),0) = 0 AS is_leaf,

  /* free text? */
  (it.item_node->>'type') IN ('string','text')           AS is_free_text,

  /* item coding */
  it.item_node#>>'{code,0,system}'                       AS item_code_system,
  it.item_node#>>'{code,0,code}'                         AS item_code_value,
  it.item_node#>>'{code,0,display}'                      AS item_code_display,

  /* domain coding */
  it.item_node#>>'{code,1,system}'                       AS domain_code_system,
  it.item_node#>>'{code,1,code}'                         AS domain_code_value,
  it.item_node#>>'{code,1,display}'                      AS domain_code_display,

  /* normalized domain key for grouping */
  lower(
    regexp_replace(
      COALESCE(
        NULLIF(btrim(it.item_node#>>'{code,1,code}'),''),
        NULLIF(btrim(it.item_node#>>'{code,1,display}'),'')
      ),
      '[^a-z0-9]+', '_', 'g'
    )
  )                                                      AS domain_key,

  /* scale metadata (best-effort):
     map ValueSet last segment to any CodeSystem with ordinals */
  cs.likert_min,
  cs.likert_max,

  /* whether this item should contribute to numeric scoring */
  CASE
    WHEN (it.item_node->>'type') = 'choice' AND cs.likert_max IS NOT NULL THEN TRUE
    WHEN (it.item_node->>'type') IN ('integer','decimal','quantity','boolean') THEN TRUE
    ELSE FALSE
  END                                                    AS is_scored

FROM item_tree it
LEFT JOIN LATERAL (
  SELECT lower(regexp_replace(it.item_node->>'answerValueSet', '^.*/', '')) AS vs_key
) vs ON TRUE
LEFT JOIN cs_ord cs
  ON cs.cs_key = vs.vs_key
WHERE it.linkid IS NOT NULL
