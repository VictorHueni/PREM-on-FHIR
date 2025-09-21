#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-pof-analytics-db}"
PGUSER="${PGUSER:-analytics_admin}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-./20250920}"
SKIP_GLOBALS="${SKIP_GLOBALS:-0}"   # set to 1 to skip globals restore

A_DUMP="${SNAPSHOT_DIR}/analytics.dump"
M_DUMP="${SNAPSHOT_DIR}/metabase.dump"
G_SQL="${SNAPSHOT_DIR}/globals.sql"

# host-side file presence only
for f in "$A_DUMP" "$M_DUMP" "$G_SQL"; do
  [[ -f "$f" ]] || { echo "Missing file: $f"; exit 1; }
done

# prevent Git-Bash path mangling of /backups/...
export MSYS_NO_PATHCONV=1

echo "→ Ensure /backups exists in container"
docker exec "$CONTAINER" sh -lc "mkdir -p /backups && chmod 777 /backups"

echo "→ Copy files into container (streamed)"
docker exec -i "$CONTAINER" sh -lc "cat > /backups/analytics.dump" < "$A_DUMP"
docker exec -i "$CONTAINER" sh -lc "cat > /backups/metabase.dump"  < "$M_DUMP"
docker exec -i "$CONTAINER" sh -lc "cat > /backups/globals.sql"     < "$G_SQL"

echo "→ Validate dumps inside container"
docker exec "$CONTAINER" sh -lc "pg_restore -l /backups/analytics.dump >/dev/null" \
  || { echo "analytics.dump looks corrupted"; exit 1; }
docker exec "$CONTAINER" sh -lc "pg_restore -l /backups/metabase.dump  >/dev/null" \
  || { echo "metabase.dump looks corrupted"; exit 1; }

if [[ "$SKIP_GLOBALS" != "1" ]]; then
  echo "→ Restore GLOBALS (ignore already-exists errors)"
  set +e
  docker exec -i "$CONTAINER" psql -U "$PGUSER" -d postgres -v ON_ERROR_STOP=0 \
    -f /backups/globals.sql
  set -e
else
  echo "→ Skipping GLOBALS as requested (SKIP_GLOBALS=1)"
fi

echo "→ Terminate sessions and drop target DBs if they exist"
docker exec "$CONTAINER" psql -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 -c \
  "SELECT pg_terminate_backend(pid)
     FROM pg_stat_activity
    WHERE datname IN ('analytics','metabase') AND pid <> pg_backend_pid();"
docker exec "$CONTAINER" dropdb -U "$PGUSER" --if-exists analytics || true
docker exec "$CONTAINER" dropdb -U "$PGUSER" --if-exists metabase  || true

echo "→ Restore ANALYTICS"
docker exec "$CONTAINER" pg_restore -U "$PGUSER" -C -d postgres -j 4 /backups/analytics.dump

echo "→ Restore METABASE"
docker exec "$CONTAINER" pg_restore -U "$PGUSER" -C -d postgres -j 4 /backups/metabase.dump

echo "✅ Restore complete. Quick checks:"
echo "  docker exec -it $CONTAINER psql -U $PGUSER -d analytics -c '\\dx'"
echo "  docker exec -it $CONTAINER psql -U $PGUSER -d analytics -c '\\dt mart.*'"
echo "  docker exec -it $CONTAINER psql -U $PGUSER -d metabase  -c '\\dt'"
