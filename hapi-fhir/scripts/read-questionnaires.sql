SELECT r.res_id, r.fhir_id, r.res_ver, r.res_published, r.res_updated
FROM hfj_resource r
WHERE r.res_type = 'Questionnaire'
ORDER BY r.res_updated DESC;

SELECT r.res_id, r.fhir_id, u.sp_uri AS canonical_url, r.res_updated
FROM hfj_spidx_uri u
JOIN hfj_resource r ON r.res_id = u.res_id
WHERE u.res_type = 'Questionnaire'
  AND u.sp_name = 'url'
  AND u.sp_uri = 'urn:uuid:prem-v1'
ORDER BY r.res_updated DESC;

SELECT r.fhir_id,
       v.res_ver,
       v.res_encoding,
       /* Prefer plain text column if present */
       v.res_text_vc
FROM hfj_resource r
JOIN hfj_res_ver v
  ON v.res_id = r.res_id AND v.res_ver = r.res_ver
WHERE r.res_type = 'Questionnaire'
  AND r.fhir_id = '1';