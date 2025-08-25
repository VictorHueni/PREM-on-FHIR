# analytics-db/Dockerfile
FROM postgres:16

# 1) Initialization SQL (runs once on first boot, against POSTGRES_DB)
COPY init/ /docker-entrypoint-initdb.d/

