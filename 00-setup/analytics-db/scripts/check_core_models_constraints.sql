-- List constraints on your core tables (by schema)
select n.nspname as schema, c.relname as table, con.conname as name,
       case con.contype
         when 'p' then 'PRIMARY KEY'
         when 'f' then 'FOREIGN KEY'
         when 'u' then 'UNIQUE'
         else con.contype::text
       end as type,
       con.convalidated as validated
from pg_constraint con
join pg_class c on c.oid = con.conrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'stg'  -- your build schema
  -- and c.relname in ('dim_patient','dim_encounter','dim_practitioner','dim_organization',
                    --'fact_prem_answer','fact_prem_response')
ORDER by type 