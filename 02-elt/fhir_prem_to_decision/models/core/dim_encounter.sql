{{ config(materialized='table') }}

select
  encounter_id,
  patient_id,
  org_id,
  practitioner_id,
  encounter_class,
  encounter_type_norm,
  class_group,
  is_inpatient,
  start_ts,
  end_ts,
  start_date,
  start_week_start,
  start_month_start
from {{ ref('stg_dim_encounters') }}