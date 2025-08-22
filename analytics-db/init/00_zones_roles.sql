-- Schemas (zones)
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS mart;

-- Roles (group roles without login)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'airbyte_loader') THEN
    CREATE ROLE airbyte_loader;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_owner') THEN
    CREATE ROLE dbt_owner;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bi_reader') THEN
    CREATE ROLE bi_reader;
  END IF;
END$$;

-- Users (login roles) - replace passwords in compose env if you prefer
-- These are placeholders so the grants below reference something concrete.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'airbyte_user') THEN
    CREATE USER airbyte_user PASSWORD 'airbyte_password';
    GRANT airbyte_loader TO airbyte_user;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_user') THEN
    CREATE USER dbt_user PASSWORD 'dbt_password';
    GRANT dbt_owner TO dbt_user;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bi_user') THEN
    CREATE USER bi_user PASSWORD 'bi_password';
    GRANT bi_reader TO bi_user;
  END IF;
END$$;

-- Lock down public
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE USAGE  ON SCHEMA public FROM PUBLIC;

-- Grants by zone
GRANT USAGE ON SCHEMA raw  TO airbyte_loader, dbt_owner;
GRANT CREATE ON SCHEMA raw TO airbyte_loader;

GRANT USAGE ON SCHEMA stg  TO dbt_owner, bi_reader;
GRANT CREATE ON SCHEMA stg TO dbt_owner;

GRANT USAGE ON SCHEMA mart TO dbt_owner, bi_reader;
GRANT CREATE ON SCHEMA mart TO dbt_owner;

-- Default privileges (future tables auto-grant reads)
ALTER DEFAULT PRIVILEGES IN SCHEMA raw  GRANT SELECT ON TABLES TO dbt_owner;
ALTER DEFAULT PRIVILEGES IN SCHEMA stg  GRANT SELECT ON TABLES TO bi_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA mart GRANT SELECT ON TABLES TO bi_reader;

-- Search paths for nicer UX (scoped to this DB)
ALTER DATABASE CURRENT_DATABASE() SET timezone   TO 'Europe/Zurich';
ALTER DATABASE CURRENT_DATABASE() SET search_path TO "$user", public;

ALTER ROLE airbyte_loader IN DATABASE CURRENT_DATABASE() SET search_path = raw, public;
ALTER ROLE dbt_owner     IN DATABASE CURRENT_DATABASE() SET search_path = stg, mart, raw, public;
ALTER ROLE bi_reader     IN DATABASE CURRENT_DATABASE() SET search_path = mart, public;

-- Extensions (create in public; pg_stat_statements requires preload set in config)
CREATE EXTENSION IF NOT EXISTS pgcrypto  WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm   WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS citext    WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;

-- Optional: make dbt own stg/mart so it can DDL freely
ALTER SCHEMA stg  OWNER TO dbt_user;
ALTER SCHEMA mart OWNER TO dbt_user;
