# Slim API image (AD-1: no source mount — code is baked, not volumed).
FROM python:3.12-slim

# curl: used by the compose healthcheck against /api/status.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Only the service code. tests/ and indexer/ are excluded via
# .dockerignore; they are not part of the running API.
COPY src/ ./src/

EXPOSE 8000

CMD ["uvicorn", "src.app:app", "--host", "0.0.0.0", "--port", "8000"]
