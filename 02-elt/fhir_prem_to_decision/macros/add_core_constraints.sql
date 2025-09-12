{% macro add_core_constraints() %}
  {% if execute %}
    {% set core_schema = var('core_schema', 'core') %}

    {% set dim_patient      = adapter.get_relation(database=target.database, schema=core_schema, identifier='dim_patient') %}
    {% set dim_encounter    = adapter.get_relation(database=target.database, schema=core_schema, identifier='dim_encounter') %}
    {% set dim_practitioner = adapter.get_relation(database=target.database, schema=core_schema, identifier='dim_practitioner') %}
    {% set dim_organization = adapter.get_relation(database=target.database, schema=core_schema, identifier='dim_organization') %}
    {% set fact_answer      = adapter.get_relation(database=target.database, schema=core_schema, identifier='fact_prem_answer') %}
    {% set fact_response    = adapter.get_relation(database=target.database, schema=core_schema, identifier='fact_prem_response') %}

    {# ---- PKs (skip missing) ---- #}
    {% if dim_patient      %} {{ add_pk_if_missing(dim_patient,      'pk_dim_patient',       'patient_id') }}      {% else %}{% do log('skip PK dim_patient (not found)',      info=True) %}{% endif %}
    {% if dim_encounter    %} {{ add_pk_if_missing(dim_encounter,    'pk_dim_encounter',     'encounter_id') }}    {% else %}{% do log('skip PK dim_encounter (not found)',    info=True) %}{% endif %}
    {% if dim_practitioner %} {{ add_pk_if_missing(dim_practitioner, 'pk_dim_practitioner',  'practitioner_id') }} {% else %}{% do log('skip PK dim_practitioner (not found)', info=True) %}{% endif %}
    {% if dim_organization %} {{ add_pk_if_missing(dim_organization, 'pk_dim_organization',  'org_id') }}          {% else %}{% do log('skip PK dim_organization (not found)', info=True) %}{% endif %}
    {% if fact_response    %} {{ add_pk_if_missing(fact_response,    'pk_fact_prem_response','qr_id') }}           {% else %}{% do log('skip PK fact_prem_response (not found)', info=True) %}{% endif %}
    {% if fact_answer      %} {{ add_pk_if_missing(fact_answer,      'pk_fpa',               'qr_id, item_linkid, answer_ordinal') }} {% else %}{% do log('skip PK fact_prem_answer (not found)', info=True) %}{% endif %}

    {# ---- FKs fact -> dims (skip if either side missing) ---- #}
    {% if fact_response and dim_patient      %} {{ add_fk_if_missing(fact_response, 'fk_fpr_patient',   'patient_id',   dim_patient,      'patient_id') }} {% endif %}
    {% if fact_response and dim_encounter    %} {{ add_fk_if_missing(fact_response, 'fk_fpr_encounter', 'encounter_id', dim_encounter,    'encounter_id') }} {% endif %}
    {% if fact_response and dim_practitioner %} {{ add_fk_if_missing(fact_response, 'fk_fpr_clinician', 'clinician_id', dim_practitioner, 'practitioner_id') }} {% endif %}
    {% if fact_response and dim_organization %} {{ add_fk_if_missing(fact_response, 'fk_fpr_org',       'org_id',       dim_organization, 'org_id') }} {% endif %}

    {% if fact_answer and dim_patient      %} {{ add_fk_if_missing(fact_answer, 'fk_fpa_patient',   'patient_id',   dim_patient,      'patient_id') }} {% endif %}
    {% if fact_answer and dim_encounter    %} {{ add_fk_if_missing(fact_answer, 'fk_fpa_encounter', 'encounter_id', dim_encounter,    'encounter_id') }} {% endif %}
    {% if fact_answer and dim_practitioner %} {{ add_fk_if_missing(fact_answer, 'fk_fpa_clinician', 'clinician_id', dim_practitioner, 'practitioner_id') }} {% endif %}
    {% if fact_answer and dim_organization %} {{ add_fk_if_missing(fact_answer, 'fk_fpa_org',       'org_id',       dim_organization, 'org_id') }} {% endif %}
  {% endif %}
{% endmacro %}
