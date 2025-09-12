-- =========================
-- Analytics DB bootstrap (+ Metabase)
-- Zones + Roles + Privileges for Airbyte + dbt + BI + Metabase
-- =========================

-- --- ZONES (schemas) ---
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS core;   
CREATE SCHEMA IF NOT EXISTS mart;

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

  -- Metabase query user (read-only over analytics)
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='metabase_ro') THEN
    CREATE USER metabase_ro PASSWORD 'change_me_ro' LOGIN;
    GRANT bi_reader TO metabase_ro;
  END IF;
END$$;

-- --- DATABASE-LEVEL PRIVILEGES (analytics DB) ---
GRANT CONNECT ON DATABASE analytics TO airbyte_user, dbt_user, bi_user, metabase_ro;
GRANT CREATE  ON DATABASE analytics TO airbyte_user, dbt_user;

-- --- OWNERSHIP / USAGE PER SCHEMA ---
-- Airbyte owns the zone it writes to
ALTER SCHEMA raw  OWNER TO airbyte_user;

-- dbt owns transformation zones
ALTER SCHEMA stg  OWNER TO dbt_user;
ALTER SCHEMA core OWNER TO dbt_user;
ALTER SCHEMA mart OWNER TO dbt_user;

-- Airbyte needs USAGE+CREATE on raw (owner already has it, but keep this if you ever switch to group roles)
GRANT USAGE, CREATE ON SCHEMA raw TO airbyte_loader;

-- dbt can read raw and build in stg/mart
GRANT USAGE  ON SCHEMA raw       TO dbt_owner;
GRANT USAGE  ON SCHEMA stg, core, mart TO dbt_owner, bi_reader;
GRANT CREATE ON SCHEMA stg, core, mart TO dbt_owner;

-- --- ONE-TIME GRANTS ON EXISTING OBJECTS ---
-- Make existing RAW readable by dbt
GRANT SELECT ON ALL TABLES    IN SCHEMA raw TO dbt_owner;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA raw TO dbt_owner;

-- Make any existing STG/MART objects readable by BI (incl. metabase_ro)
GRANT SELECT ON ALL TABLES    IN SCHEMA stg, core, mart TO bi_reader;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA stg, core, mart TO bi_reader;

-- --- DEFAULT PRIVILEGES (future objects) ---
-- Objects created by AIRBYTE in raw -> readable by dbt
ALTER DEFAULT PRIVILEGES FOR ROLE airbyte_user IN SCHEMA raw
  GRANT SELECT ON TABLES TO dbt_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE airbyte_user IN SCHEMA raw
  GRANT USAGE, SELECT ON SEQUENCES TO dbt_owner;

-- Objects created by DBT in stg/mart -> readable by BI (incl. metabase_ro)
ALTER DEFAULT PRIVILEGES FOR ROLE dbt_user IN SCHEMA stg
  GRANT SELECT ON TABLES TO bi_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE dbt_user IN SCHEMA stg
  GRANT USAGE, SELECT ON SEQUENCES TO bi_reader;

ALTER DEFAULT PRIVILEGES FOR ROLE dbt_user IN SCHEMA core
  GRANT SELECT ON TABLES TO bi_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE dbt_user IN SCHEMA core
  GRANT USAGE, SELECT ON SEQUENCES TO bi_reader;


ALTER DEFAULT PRIVILEGES FOR ROLE dbt_user IN SCHEMA mart
  GRANT SELECT ON TABLES TO bi_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE dbt_user IN SCHEMA mart
  GRANT USAGE, SELECT ON SEQUENCES TO bi_reader;

-- --- LOCK DOWN PUBLIC ---
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE USAGE  ON SCHEMA public FROM PUBLIC;

-- Allow required users to use functions/types in public (extensions live here)
GRANT USAGE ON SCHEMA public TO airbyte_user, dbt_user, bi_user, metabase_ro;

-- --- SEARCH PATHS & TIME ZONE (analytics DB) ---
ALTER DATABASE analytics SET timezone    TO 'Europe/Zurich';
ALTER DATABASE analytics SET search_path TO '"$user", public';

ALTER ROLE airbyte_user IN DATABASE analytics SET search_path = raw, public;
ALTER ROLE dbt_user     IN DATABASE analytics SET search_path = raw, stg, core, mart, public;
ALTER ROLE bi_user      IN DATABASE analytics SET search_path = core, mart, public;
ALTER ROLE metabase_ro  IN DATABASE analytics SET search_path = core, mart, public;

-- --- EXTENSIONS (in public) ---
CREATE EXTENSION IF NOT EXISTS pgcrypto           WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp"        WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm            WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS citext             WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;