-- ============================================
-- 00-users-zones: Airbyte read-only on OLTP
-- Publish only curated export views
-- ============================================

-- 1) Login principal Airbyte will use
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'airbyte_ro') THEN
    -- You can keep LOGIN here if you prefer a single principal.
    -- Alternative pattern: CREATE ROLE airbyte_ro NOLOGIN; CREATE USER airbyte_src LOGIN; GRANT airbyte_ro TO airbyte_src;
    CREATE ROLE airbyte_ro LOGIN PASSWORD 'strong_readonly_pw';
  END IF;
END$$;

-- 2) Connector needs to reach the DB
GRANT CONNECT ON DATABASE prem_on_fhir TO airbyte_ro;

-- 3) A dedicated export schema that only contains light views
--    (no heavy JSON explosions here—do those in the analytics DB)
CREATE SCHEMA IF NOT EXISTS airbyte_export;

-- Set a clear owner (usually your admin/hapi owner role)
-- so the owner retains base-table access and can manage view DDL.
ALTER SCHEMA airbyte_export OWNER TO CURRENT_USER;

COMMENT ON SCHEMA airbyte_export IS 'Read-only export surface for Airbyte (safe views only)';

-- 4) Grant Airbyte read-only on the export surface ONLY
GRANT USAGE ON SCHEMA airbyte_export TO airbyte_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA airbyte_export TO airbyte_ro;

-- Future-proof: any new views you add to airbyte_export should auto-grant SELECT to Airbyte
ALTER DEFAULT PRIVILEGES IN SCHEMA airbyte_export GRANT SELECT ON TABLES TO airbyte_ro;

-- 5) (Optional) Convenience: set search_path for this principal
ALTER ROLE airbyte_ro IN DATABASE prem_on_fhir
  SET search_path = airbyte_export, public;

-- 6) (Important) DO NOT blanket-grant public:
--    Avoid: GRANT SELECT ON ALL TABLES IN SCHEMA public TO airbyte_ro;
--    Keep app tables private. Airbyte will only see airbyte_export.*
