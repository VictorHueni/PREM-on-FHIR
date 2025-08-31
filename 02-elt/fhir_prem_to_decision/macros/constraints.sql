{% macro add_pk_if_missing(this_relation, pk_name, cols) %}
  {% set check_sql %}
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where c.conname = '{{ pk_name }}'
      and n.nspname = '{{ this_relation.schema }}'
      and t.relname = '{{ this_relation.identifier }}'
  {% endset %}
  {% set res = run_query(check_sql) %}
  {% if res is not none and res.rows|length > 0 %}
    {% do log("PK " ~ pk_name ~ " already exists on " ~ this_relation, info=True) %}
  {% else %}
    {% set ddl %}alter table {{ this_relation }} add constraint {{ pk_name }} primary key ({{ cols }});{% endset %}
    {% do log("Creating PK " ~ pk_name ~ " on " ~ this_relation, info=True) %}
    {% do run_query(ddl) %}
  {% endif %}
{% endmacro %}

{% macro add_fk_if_missing(this_relation, fk_name, col, target_relation, target_col) %}
  {% set check_sql %}
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where c.conname = '{{ fk_name }}'
      and n.nspname = '{{ this_relation.schema }}'
      and t.relname = '{{ this_relation.identifier }}'
  {% endset %}
  {% set res = run_query(check_sql) %}
  {% if res is not none and res.rows|length > 0 %}
    {% do log("FK " ~ fk_name ~ " already exists on " ~ this_relation, info=True) %}
  {% else %}
    {% set ddl1 %}
      alter table {{ this_relation }}
      add constraint {{ fk_name }}
      foreign key ({{ col }}) references {{ target_relation }} ({{ target_col }})
      not valid;
    {% endset %}
    {% set ddl2 %}alter table {{ this_relation }} validate constraint {{ fk_name }};{% endset %}
    {% do log("Creating & validating FK " ~ fk_name ~ " on " ~ this_relation, info=True) %}
    {% do run_query(ddl1) %}
    {% do run_query(ddl2) %}
  {% endif %}
{% endmacro %}
