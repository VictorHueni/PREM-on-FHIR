{{ config(materialized='view') }}

{{ config(materialized='view') }}

WITH src AS (
  SELECT
    encounter_id,
    patient_ref,
    org_ref,
    practitioner_ref,
    start_ts,
    end_ts,
    status,
    resource::jsonb AS resource_jsonb
  FROM {{ source('raw','encounter_current') }}
),
base AS (
  SELECT
    s.encounter_id,
    s.patient_ref,
    s.org_ref,
    /* prefer explicit column; fall back to participant[0] */
    COALESCE(s.practitioner_ref, s.resource_jsonb#>>'{participant,0,individual,reference}')
                                                    AS practitioner_ref,
    s.start_ts,
    s.end_ts,
    s.status,
    /* descriptive type */
    COALESCE(
      s.resource_jsonb#>>'{type,0,text}',
      s.resource_jsonb#>>'{type,0,coding,0,display}',
      s.resource_jsonb#>>'{type,0,coding,0,code}'
    )                                               AS encounter_type,
    s.resource_jsonb#>>'{type,0,coding,0,code}'     AS encounter_type_code,
    s.resource_jsonb#>>'{type,0,coding,0,system}'   AS encounter_type_system,
    s.resource_jsonb#>>'{class,code}'               AS encounter_class
  FROM src s
)

SELECT
  b.*,

  /* clean IDs from refs */
  NULLIF(split_part(COALESCE(b.patient_ref,''),       '/', 2),'') AS patient_id,
  NULLIF(split_part(COALESCE(b.org_ref,''),           '/', 2),'') AS org_id,
  NULLIF(split_part(COALESCE(b.practitioner_ref,''),  '/', 2),'') AS practitioner_id,

  /* duration */
  CASE
    WHEN b.start_ts IS NOT NULL AND b.end_ts IS NOT NULL
      THEN (EXTRACT(EPOCH FROM (b.end_ts - b.start_ts)) / 60.0)::int
  END                                                       AS duration_minutes,

  /* buckets in a single reporting TZ */
  (b.start_ts  AT TIME ZONE '{{ var("report_tz","UTC") }}')::date              AS start_date,
  date_trunc('week',  b.start_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::date AS start_week_start,
  to_char(date_trunc('week', b.start_ts AT TIME ZONE '{{ var("report_tz","UTC") }}'), 'IYYY-"W"IW') AS start_week_label,
  date_trunc('month', b.start_ts AT TIME ZONE '{{ var("report_tz","UTC") }}')::date AS start_month_start,

  /* normalized labels */
  COALESCE(NULLIF(lower(btrim(b.encounter_type)),''),'unknown')  AS encounter_type_norm,

  CASE
    WHEN b.encounter_class IN ('IMP','INPATIENT') THEN 'inpatient'
    WHEN b.encounter_class IN ('AMB','OUTPATIENT') THEN 'outpatient'
    WHEN b.encounter_class IN ('EMER','ER','ED')   THEN 'emergency'
    ELSE 'other'
  END                                                       AS class_group,

  (b.encounter_class IN ('IMP','INPATIENT'))                AS is_inpatient
FROM base b
