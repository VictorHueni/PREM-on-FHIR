# analytics-db/Dockerfile
FROM postgres:16

# 1) Initialization SQL (runs once on first boot, against POSTGRES_DB)
COPY init/ /docker-entrypoint-initdb.d/

# 2) Custom config (timezone, extensions, pg_stat_statements preload)
COPY conf/postgresql.analytics.conf /etc/postgresql/postgresql.analytics.conf
