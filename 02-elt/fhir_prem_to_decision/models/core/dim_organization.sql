{{ config(materialized='table') }}

select
  org_id,
  name,
  org_slug,
  org_kind_norm,
  is_active
from {{ ref('stg_dim_organizations') }}