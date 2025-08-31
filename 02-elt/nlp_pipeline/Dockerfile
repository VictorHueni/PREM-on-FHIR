# syntax=docker/dockerfile:1.7
FROM python:3.11-slim-bookworm

# Lean, predictable Python + HF cache location
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/app/.hf_cache

# Runtime deps only (no compilers). tini = clean signal handling.
# psycopg2-binary ships its own libpq, so libpq5 is optional; keeping it is tiny.
RUN apt-get update && apt-get install -y --no-install-recommends \
      tini libpq5 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 1) Install Python deps first to leverage layer cache
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt

# 2) Copy just what we need (avoid pulling in venv/.hf_cache/git/etc.)
COPY pipeline/ /app/pipeline/
COPY config.yaml themes.yml /app/

# Non-root user + writable cache dir
RUN useradd -m -u 10001 appuser && \
    mkdir -p /app/.hf_cache && \
    chown -R appuser:appuser /app
USER appuser

# Keep model cache outside the image; persist across runs
VOLUME ["/app/.hf_cache"]

# Default command (overridable at `docker run`)
ENTRYPOINT ["/usr/bin/tini","--","python","-m","pipeline.cli"]
CMD ["--help"] 
# CMD ["score","--since","90d","--limit","500"]
