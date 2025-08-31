FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    DBT_PROFILES_DIR=/usr/app

# git (for dbt deps), certs, tini (signal handling), libpq for psycopg2-binary
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates tini libpq5 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/app

# Install Python deps first for better layer caching
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir -r requirements.txt

ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["dbt","--help"]