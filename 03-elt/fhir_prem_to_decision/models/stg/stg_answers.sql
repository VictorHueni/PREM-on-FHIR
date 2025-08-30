{{ config(materialized='view') }}

WITH RECURSIVE

-- 1) Pull the QR JSON we need (robust fallback for questionnaire id)
qrs AS (
  SELECT
    COALESCE(qr_id, (resource::jsonb->>'id'))                    AS qr_id,
    authored_ts,
    questionnaire_ref,
    /* FIX: proper fallback for both URL and relative ref */
    CASE
      WHEN COALESCE(questionnaire_ref, resource::jsonb->>'questionnaire') ~* '^https?://'
        THEN regexp_replace(COALESCE(questionnaire_ref, resource::jsonb->>'questionnaire'), '^.*/', '')
      ELSE split_part(COALESCE(questionnaire_ref, resource::jsonb->>'questionnaire'), '/', 2)
    END                                                         AS questionnaire_id_fallback,
    patient_ref,
    encounter_ref,
    author_ref,
    resource::jsonb                                              AS resource_jsonb
  FROM {{ source('raw', 'questionnaireresponse_current') }}
),

-- 2) Walk the QR.item tree and explode answers
item_tree AS (
  -- roots
  SELECT
    q.qr_id, q.authored_ts, q.questionnaire_id_fallback, q.patient_ref, q.encounter_ref, q.author_ref,
    (i->>'linkId')::text AS linkid,
    i                    AS item_node
  FROM qrs q
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(q.resource_jsonb->'item','[]'::jsonb)) AS i

  UNION ALL

  -- children
  SELECT
    it.qr_id, it.authored_ts, it.questionnaire_id_fallback, it.patient_ref, it.encounter_ref, it.author_ref,
    (i->>'linkId')::text AS linkid,
    i                    AS item_node
  FROM item_tree it
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(it.item_node->'item','[]'::jsonb)) AS i
),

answers AS (
  SELECT
    it.qr_id,
    it.authored_ts,
    it.questionnaire_id_fallback,
    it.patient_ref,
    it.encounter_ref,
    it.author_ref AS clinician_ref,
    it.linkid     AS item_linkid,
    ans,
    row_number() OVER (PARTITION BY it.qr_id, it.linkid ORDER BY 1) AS answer_ordinal
  FROM item_tree it
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(it.item_node->'answer','[]'::jsonb)) AS ans
),

-- 3) CodeSystem → (display, ordinal) map
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

-- 4) Base projections
base AS (
  SELECT
    a.qr_id,
    a.authored_ts,
    a.questionnaire_id_fallback,
    a.patient_ref,
    a.encounter_ref,
    a.clinician_ref,
    a.item_linkid,
    a.answer_ordinal,

    a.ans->>'valueString'             AS value_string,
    (a.ans->>'valueInteger')::int     AS value_integer,
    (a.ans->>'valueDecimal')::numeric AS value_decimal,
    (a.ans->>'valueBoolean')::boolean AS value_boolean,
    a.ans->>'valueDateTime'           AS value_datetime,
    a.ans->>'valueDate'               AS value_date,
    a.ans->>'valueTime'               AS value_time,
    a.ans->'valueQuantity'->>'value'  AS value_quantity,
    a.ans->'valueQuantity'->>'unit'   AS value_quantity_unit,

    a.ans->'valueCoding'->>'system'   AS value_coding_system,
    a.ans->'valueCoding'->>'code'     AS value_code,
    COALESCE(a.ans->'valueCoding'->>'display', cs.display) AS value_display,

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
    END AS answer_kind,

    CASE
      WHEN cs.ordinal_value IS NOT NULL THEN cs.ordinal_value
      WHEN a.ans ? 'valueInteger'       THEN (a.ans->>'valueInteger')::numeric
      WHEN a.ans ? 'valueDecimal'       THEN (a.ans->>'valueDecimal')::numeric
      WHEN a.ans ? 'valueBoolean'       THEN CASE a.ans->>'valueBoolean' WHEN 'true' THEN 1 ELSE 0 END
      WHEN a.ans ? 'valueQuantity'
           AND (a.ans->'valueQuantity'->>'value') ~ '^-?[0-9]+(\.[0-9]+)?$'
                                         THEN (a.ans->'valueQuantity'->>'value')::numeric
      WHEN a.ans ? 'valueCoding'
           AND (a.ans->'valueCoding'->>'code') ~ '^[0-9]+(\.[0-9]+)?$'
                                         THEN (a.ans->'valueCoding'->>'code')::numeric
      ELSE NULL
    END AS numeric_value
  FROM answers a
  LEFT JOIN cs
    ON a.ans ? 'valueCoding'
   AND cs.system = (a.ans->'valueCoding'->>'system')
   AND cs.code   = (a.ans->'valueCoding'->>'code')
),

-- 5) Normalized keys & buckets from stg_responses
resp AS (
  SELECT
    qr_id,
    authored_ts,
    questionnaire_id,
    qr_date,
    qr_week_start  AS qr_week,
    qr_month_start AS qr_month,
    patient_id,
    encounter_id,
    clinician_id,
    org_id
  FROM {{ ref('stg_responses') }}
),

-- 6) Item dictionary (leaf-only), WITH normalized key
itm AS (
  SELECT
    questionnaire_key,       -- <— from stg_items fix above
    questionnaire_id,        -- original logical id (kept in case you need it)
    linkid,
    domain_key,
    domain_code_value   AS item_domain,
    domain_code_system  AS item_domain_system,
    is_scored,
    is_free_text,
    is_leaf
  FROM {{ ref('stg_items') }}
),

-- 7) Observed max ordinal
ordinals AS (
  SELECT
    COALESCE(r.questionnaire_id, b.questionnaire_id_fallback) AS questionnaire_id_norm,
    b.item_linkid,
    MAX(b.numeric_value) FILTER (WHERE b.answer_kind = 'coding') AS max_ordinal_observed
  FROM base b
  LEFT JOIN resp r ON r.qr_id = b.qr_id
  GROUP BY 1,2
),

-- 8) Patient DOB
pat AS (
  SELECT patient_id, birth_date
  FROM {{ ref('stg_dim_patients') }}
)

SELECT
  md5(
    coalesce(b.qr_id,'') || '|' ||
    coalesce(b.item_linkid,'') || '|' ||
    coalesce(b.answer_ordinal::text,'')
  )                                           AS answer_id,

  b.qr_id,

  COALESCE(r.questionnaire_id, b.questionnaire_id_fallback) AS questionnaire_id,
  r.qr_date,
  r.qr_week,
  r.qr_month,

  b.authored_ts,

  b.patient_ref,
  b.encounter_ref,
  b.clinician_ref,
  r.patient_id,
  r.encounter_id,
  r.clinician_id,
  r.org_id,

  b.item_linkid,
  i.domain_key,
  i.item_domain,
  i.item_domain_system,
  i.is_leaf,
  i.is_scored,

  b.answer_ordinal,
  b.answer_kind,
  b.numeric_value,
  b.value_string,
  b.value_display,
  b.value_code,
  b.value_coding_system,

  o.max_ordinal_observed                      AS likert_max_for_item,
  CASE
    WHEN b.answer_kind='coding'
     AND o.max_ordinal_observed IS NOT NULL
     AND o.max_ordinal_observed > 0
      THEN b.numeric_value / o.max_ordinal_observed
  END                                         AS score_pct,

  (b.answer_kind='string')                    AS is_free_text,
  (b.answer_kind='coding' AND o.max_ordinal_observed IS NOT NULL)
                                              AS has_ordinal,

  CASE
    WHEN b.answer_kind='coding'
     AND o.max_ordinal_observed IS NOT NULL
     AND b.numeric_value = o.max_ordinal_observed
      THEN TRUE ELSE FALSE
  END                                         AS answer_is_top_box,

  CASE
    WHEN b.answer_kind='coding'
     AND o.max_ordinal_observed IS NOT NULL
     AND b.numeric_value >= (o.max_ordinal_observed - 1)
      THEN TRUE ELSE FALSE
  END                                         AS answer_is_top2_box,

  CASE
    WHEN b.answer_kind='coding'
     AND b.value_coding_system ILIKE '%likert%'
     AND b.numeric_value IN (0,1)
      THEN TRUE ELSE FALSE
  END                                         AS answer_is_bottom_box,

  (b.value_coding_system ILIKE '%nps%' OR b.value_coding_system ILIKE '%/nps-%') AS is_nps,
  CASE
    WHEN (b.value_coding_system ILIKE '%nps%' OR b.value_coding_system ILIKE '%/nps-%')
     AND b.numeric_value BETWEEN 0 AND 6  THEN 'detractor'
    WHEN (b.value_coding_system ILIKE '%nps%' OR b.value_coding_system ILIKE '%/nps-%')
     AND b.numeric_value BETWEEN 7 AND 8  THEN 'passive'
    WHEN (b.value_coding_system ILIKE '%nps%' OR b.value_coding_system ILIKE '%/nps-%')
     AND b.numeric_value BETWEEN 9 AND 10 THEN 'promoter'
  END                                         AS nps_bucket,

  CASE WHEN b.answer_kind='string'
       THEN lower(regexp_replace(coalesce(b.value_string,''),'[^[:alnum:]\s]+','','g'))
  END                                         AS value_string_clean,

  CASE
    WHEN p.birth_date IS NOT NULL
    THEN date_part(
           'year',
           age( (b.authored_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::date
             , p.birth_date )
         )::int
  END                                         AS age_at_authored

FROM base b
LEFT JOIN resp r
  ON r.qr_id = b.qr_id
LEFT JOIN itm i
  ON i.questionnaire_key = COALESCE(r.questionnaire_id, b.questionnaire_id_fallback)  -- << key fix
 AND i.linkid            = b.item_linkid
LEFT JOIN ordinals o
  ON o.questionnaire_id_norm = COALESCE(r.questionnaire_id, b.questionnaire_id_fallback)
 AND o.item_linkid           = b.item_linkid
LEFT JOIN pat p
  ON p.patient_id       = r.patient_id

-- Keep only leaf items once the join works; temporarily you can relax this if debugging
WHERE i.is_leaf = TRUE
