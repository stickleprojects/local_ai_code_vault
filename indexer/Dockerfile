# Ephemeral indexer image — run per job: `docker run --rm`.
# No source is baked except this app; the target repo is bind-mounted
# read-only at /repo by the Phase 2 launcher script.
FROM python:3.12-slim

# git: compute_head_sha() reads the mounted repo's HEAD.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependency layer first for build-cache friendliness.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Shared embedding contract (src/models.py) + the indexer package.
COPY src/ ./src/
COPY indexer/ ./indexer/

# The repo to index is mounted here read-only at run time.
VOLUME ["/repo"]

ENTRYPOINT ["python", "-m", "indexer.index"]
CMD ["--help"]
