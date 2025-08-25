-- Create a dedicated read-only user for Airbyte (standard/incremental syncs)
CREATE USER airbyte_ro WITH PASSWORD 'strong_readonly_pw';

-- Allow connections to the HAPI database
GRANT CONNECT ON DATABASE prem_on_fhir TO airbyte_ro;

-- Switch to the HAPI DB (pgAdmin does this with \c; here we grant at DB level)
-- Grants on the public schema (HAPI JPA uses public by default)
GRANT USAGE ON SCHEMA public TO airbyte_ro;

-- Allow reading existing tables and sequences
GRANT SELECT ON ALL TABLES IN SCHEMA public TO airbyte_ro;
GRANT USAGE  ON ALL SEQUENCES IN SCHEMA public TO airbyte_ro;

-- Ensure future tables are also readable (important as HAPI creates more)
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES   TO airbyte_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE  ON SEQUENCES TO airbyte_ro;

-- (Optional) Narrow to just the tables you need later if you want tighter scope.

-- (Optional) CDC user for later (comment out if not using CDC yet)
-- CREATE ROLE airbyte_cdc WITH LOGIN REPLICATION PASSWORD 'strong_replication_pw';
-- GRANT CONNECT ON DATABASE prem_on_fhir TO airbyte_cdc;
