{{ config(materialized='view') }}

WITH src AS (
  SELECT
    org_id,
    resource::jsonb                    AS resource_jsonb,
    _airbyte_extracted_at              AS loaded_at,
    _airbyte_meta::jsonb               AS airbyte_meta
  FROM {{ source('raw','organization_current') }}
),
base AS (
  SELECT
    COALESCE(s.org_id, s.resource_jsonb->>'id')       AS org_id,
    s.resource_jsonb->>'name'                          AS name,
    (s.resource_jsonb->>'active')::boolean             AS is_active,

    -- Organization.type[0]
    s.resource_jsonb#>>'{type,0,coding,0,system}'      AS type_system,
    s.resource_jsonb#>>'{type,0,coding,0,code}'        AS type_code,
    s.resource_jsonb#>>'{type,0,coding,0,display}'     AS type_display,
    s.resource_jsonb#>>'{type,0,text}'                 AS type_text,

    -- Hierarchy
    s.resource_jsonb#>>'{partOf,reference}'            AS parent_org_ref,

    -- Telecom (prefer work > main > any phone)
    (
      SELECT t->>'value'
      FROM jsonb_array_elements(COALESCE(s.resource_jsonb->'telecom','[]'::jsonb)) t
      WHERE t->>'system' = 'phone'
      ORDER BY CASE t->>'use'
                WHEN 'work' THEN 0
                WHEN 'temp' THEN 1
                WHEN 'mobile' THEN 2
                WHEN 'home' THEN 3
                WHEN 'old' THEN 98
                ELSE 99
              END
      LIMIT 1
    )                                                  AS phone_primary,

    -- Address (first)
    s.resource_jsonb#>>'{address,0,line,0}'            AS address_line1,
    s.resource_jsonb#>>'{address,0,city}'              AS address_city,
    s.resource_jsonb#>>'{address,0,state}'             AS address_state,
    s.resource_jsonb#>>'{address,0,postalCode}'        AS address_postal_code,
    s.resource_jsonb#>>'{address,0,country}'           AS address_country,

    -- Identifier (first)
    s.resource_jsonb#>>'{identifier,0,system}'         AS identifier_system,
    s.resource_jsonb#>>'{identifier,0,value}'          AS identifier_value,

    s.loaded_at,
    s.resource_jsonb
  FROM src s
  WHERE COALESCE(s.org_id, s.resource_jsonb->>'id') IS NOT NULL
)

SELECT
  b.org_id,
  b.name,
  NULLIF(trim(b.name), '')                              AS name_clean,
  -- slug for grouping despite punctuation/case differences
  btrim(
    regexp_replace(lower(COALESCE(b.name,'')), '[^a-z0-9]+', '-', 'g'),
    '-'
  )                                                     AS org_slug,

  b.is_active,

  b.type_system,
  b.type_code,
  b.type_display,
  b.type_text,

  -- normalized kind from HL7 organization-type codes
  CASE lower(COALESCE(b.type_code,''))
    WHEN 'prov'  THEN 'provider'
    WHEN 'dept'  THEN 'department'
    WHEN 'team'  THEN 'team'
    WHEN 'pay'   THEN 'payor'
    WHEN 'ins'   THEN 'insurer'
    WHEN 'govt'  THEN 'government'
    WHEN 'edu'   THEN 'education'
    WHEN 'reli'  THEN 'religious'
    WHEN 'crs'   THEN 'clinical-research'
    WHEN 'other' THEN 'other'
    WHEN ''      THEN 'unknown'
    ELSE 'other'
  END                                                   AS org_kind_norm,

  b.parent_org_ref,
  NULLIF(split_part(COALESCE(b.parent_org_ref,''), '/', 2), '') AS parent_org_id,
  (b.parent_org_ref IS NULL)                          AS is_top_level,

  b.phone_primary,

  b.address_line1,
  b.address_city,
  b.address_state,
  b.address_postal_code,
  b.address_country,
  (b.address_line1 IS NOT NULL OR b.address_city IS NOT NULL)   AS has_address,
  b.address_state                                               AS region_state,

  b.identifier_system,
  b.identifier_value,

  b.loaded_at
FROM base b
