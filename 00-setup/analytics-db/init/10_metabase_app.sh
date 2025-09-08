#!/usr/bin/env bash
set -euo pipefail

: "${MB_DB_NAME:=metabase}"
: "${MB_DB_USER:=metabase_app}"
: "${MB_DB_PASS:=change_me_strong}"
: "${POSTGRES_DB:=postgres}"   # safe DB to connect to (fallback)

echo "Setting up Metabase application database '${MB_DB_NAME}' and role '${MB_DB_USER}'"

# 1) Create/align role (OK inside DO)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${MB_DB_USER}') THEN
    CREATE ROLE ${MB_DB_USER} LOGIN PASSWORD '${MB_DB_PASS}';
  ELSE
    ALTER ROLE ${MB_DB_USER} WITH LOGIN PASSWORD '${MB_DB_PASS}';
  END IF;
END
\$\$;
EOSQL

# 2) Create DB outside any transaction
EXISTS=$(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT 1 FROM pg_database WHERE datname='${MB_DB_NAME}'")
if [ -z "$EXISTS" ]; then
  createdb -U "$POSTGRES_USER" -O "$MB_DB_USER" "$MB_DB_NAME"
fi

# 3) Ensure ownership/privs (safe if DB already exists)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
ALTER DATABASE "${MB_DB_NAME}" OWNER TO ${MB_DB_USER};
GRANT ALL PRIVILEGES ON DATABASE "${MB_DB_NAME}" TO ${MB_DB_USER};
EOSQL
