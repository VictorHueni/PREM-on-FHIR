{{ config(materialized='table') }}

select
  patient_id,
  gender_norm,
  birth_date,
  age_current,
  age_band_current,
  language_code,
  language_display,
  patient_pseudonym,
  (phone_primary is not null) as has_phone,
  has_address
from {{ ref('stg_dim_patients') }}