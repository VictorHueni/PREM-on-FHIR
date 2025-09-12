{{ config(materialized='table', schema='mart') }}

select
  fr.authored_ts::date                      as period_date,
  fr.questionnaire_id,
  count(*)                                  as responses_n,
  count(distinct fr.patient_id)             as patients_n
from {{ ref('fact_prem_response') }} fr
group by 1,2
