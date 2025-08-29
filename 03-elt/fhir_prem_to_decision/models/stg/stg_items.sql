
WITH RECURSIVE
src AS (
  SELECT
    questionnaire_id,
    resource::jsonb AS resource_jsonb
  FROM {{ source('raw', 'questionnaire_current') }}
),

-- recursive walk of item tree
item_tree AS (
  -- root items
  SELECT
    s.questionnaire_id,
    (i->>'linkId')::text AS linkid,
    i                    AS item_node
  FROM src s
  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(s.resource_jsonb->'item','[]'::jsonb)
  ) AS i

  UNION ALL

  -- nested items
  SELECT
    it.questionnaire_id,
    (i->>'linkId')::text AS linkid,
    i                    AS item_node
  FROM item_tree it
  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(it.item_node->'item','[]'::jsonb)
  ) AS i
)

SELECT DISTINCT
  questionnaire_id,
  linkid,
  item_node->>'text'          AS question_text,
  item_node->>'type'          AS question_type,
  (item_node->>'required')::boolean AS is_required,
  item_node->>'answerValueSet'      AS answer_valueset,

  -- first code (item)
  item_node#>>'{code,0,system}'   AS item_code_system,
  item_node#>>'{code,0,code}'     AS item_code_value,
  item_node#>>'{code,0,display}'  AS item_code_display,

  -- second code (domain)
  item_node#>>'{code,1,system}'   AS domain_code_system,
  item_node#>>'{code,1,code}'     AS domain_code_value,
  item_node#>>'{code,1,display}'  AS domain_code_display
FROM item_tree
WHERE linkid IS NOT NULL