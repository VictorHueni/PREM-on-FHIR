{{ config(materialized='table') }}

select
  practitioner_id,
  gender_norm,
  full_name,
  clinician_slug,
  clinician_pseudonym,
  npi,
  email_primary,
  phone_primary,
  (phone_primary is not null) as has_phone,
  (email_primary is not null) as has_email
from {{ ref('stg_dim_practitioners') }}