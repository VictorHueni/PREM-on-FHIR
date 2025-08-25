-- =========================
-- Analytics DB bootstrap
-- Zones + Roles + Privileges for Airbyte + dbt + BI
-- =========================

-- --- ZONES (schemas) ---
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS mart;
-- Airbyte uses this when "Raw table schema" is left blank
CREATE SCHEMA IF NOT EXISTS airbyte_internal;

-- --- ROLE GROUPS (no login) ---
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='airbyte_loader') THEN
    CREATE ROLE airbyte_loader NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='dbt_owner') THEN
    CREATE ROLE dbt_owner NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='bi_reader') THEN
    CREATE ROLE bi_reader NOLOGIN;
  END IF;
END$$;

-- --- USERS (login) ---
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='airbyte_user') THEN
    CREATE USER airbyte_user PASSWORD 'airbyte_password' LOGIN;
    GRANT airbyte_loader TO airbyte_user;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='dbt_user') THEN
    CREATE USER dbt_user PASSWORD 'dbt_password' LOGIN;
    GRANT dbt_owner TO dbt_user;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='bi_user') THEN
    CREATE USER bi_user PASSWORD 'bi_password' LOGIN;
    GRANT bi_reader TO bi_user;
  END IF;
END$$;

-- --- DATABASE-LEVEL PRIVILEGES ---
-- Airbyte and dbt must be able to create schemas/tables in this database.
GRANT CONNECT ON DATABASE analytics TO airbyte_user, dbt_user, bi_user;
GRANT CREATE  ON DATABASE analytics TO airbyte_user, dbt_user;

-- --- OWNERSHIP / USAGE PER SCHEMA ---
-- Make Airbyte the owner of the zones it writes to, or at least allow CREATE.
ALTER SCHEMA raw              OWNER TO airbyte_user;
ALTER SCHEMA airbyte_internal OWNER TO airbyte_user;

-- dbt owns transformation zones so it can run DDL freely.
ALTER SCHEMA stg  OWNER TO dbt_user;
ALTER SCHEMA mart OWNER TO dbt_user;

-- USAGE/CREATE by role groups (principals inherit via group membership)
GRANT USAGE  ON SCHEMA raw, airbyte_internal   TO airbyte_loader, dbt_owner;
GRANT CREATE ON SCHEMA raw, airbyte_internal   TO airbyte_loader;

GRANT USAGE  ON SCHEMA stg, mart               TO dbt_owner, bi_reader;
GRANT CREATE ON SCHEMA stg, mart               TO dbt_owner;

-- --- DEFAULT PRIVILEGES (future objects) ---
-- 1) Objects created by AIRBYTE in raw/airbyte_internal should be readable by dbt.
ALTER DEFAULT PRIVILEGES FOR ROLE airbyte_user IN SCHEMA raw
  GRANT SELECT ON TABLES TO dbt_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE airbyte_user IN SCHEMA raw
  GRANT USAGE, SELECT ON SEQUENCES TO dbt_owner;

ALTER DEFAULT PRIVILEGES FOR ROLE airbyte_user IN SCHEMA airbyte_internal
  GRANT SELECT ON TABLES TO dbt_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE airbyte_user IN SCHEMA airbyte_internal
  GRANT USAGE, SELECT ON SEQUENCES TO dbt_owner;

-- 2) Objects created by DBT in stg/mart should be readable by BI users.
ALTER DEFAULT PRIVILEGES FOR ROLE dbt_user IN SCHEMA stg
  GRANT SELECT ON TABLES TO bi_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE dbt_user IN SCHEMA stg
  GRANT USAGE, SELECT ON SEQUENCES TO bi_reader;

ALTER DEFAULT PRIVILEGES FOR ROLE dbt_user IN SCHEMA mart
  GRANT SELECT ON TABLES TO bi_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE dbt_user IN SCHEMA mart
  GRANT USAGE, SELECT ON SEQUENCES TO bi_reader;

-- --- LOCK DOWN PUBLIC ---
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE USAGE  ON SCHEMA public FROM PUBLIC;

-- --- SEARCH PATHS & TIME ZONE ---
ALTER DATABASE CURRENT_DATABASE() SET timezone     TO 'Europe/Zurich';
ALTER DATABASE CURRENT_DATABASE() SET search_path TO "$user", public;

ALTER ROLE airbyte_loader IN DATABASE CURRENT_DATABASE() SET search_path = raw, airbyte_internal, public;
ALTER ROLE dbt_owner     IN DATABASE CURRENT_DATABASE() SET search_path = stg, mart, raw, public;
ALTER ROLE bi_reader     IN DATABASE CURRENT_DATABASE() SET search_path = mart, public;

-- --- EXTENSIONS (in public) ---
CREATE EXTENSION IF NOT EXISTS pgcrypto           WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp"        WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm            WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS citext             WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;

-- (Optional) If other owners already exist on these schemas and you want to preserve them,
-- you can keep GRANT CREATE instead of ALTER SCHEMA ... OWNER TO ..