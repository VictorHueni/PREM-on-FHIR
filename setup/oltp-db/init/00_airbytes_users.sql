-- idempotent Airbyte RO role + grants
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'airbyte_ro') THEN
    CREATE ROLE airbyte_ro LOGIN PASSWORD 'strong_readonly_pw';
  END IF;
END$$;

GRANT CONNECT ON DATABASE prem_on_fhir TO airbyte_ro;

-- run these inside prem_on_fhir (you are when you use -d prem_on_fhir)
GRANT USAGE ON SCHEMA public TO airbyte_ro;

GRANT SELECT ON ALL TABLES    IN SCHEMA public TO airbyte_ro;
GRANT USAGE  ON ALL SEQUENCES IN SCHEMA public TO airbyte_ro;

-- default privileges apply to objects created by the *current role* (admin),
-- which is what HAPI uses, so this is the right place to set them:
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES    TO airbyte_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE  ON SEQUENCES TO airbyte_ro;
