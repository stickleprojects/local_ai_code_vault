"""Shared schemas and the embedding contract constants.

Single source of truth for:
  * the embedding vector dimension (AD-7 / BLOCKER B-1 resolution), and
  * the query/code prompt-prefix asymmetry (AD-10).

Both the API query path and the future indexer MUST import the prefix
helpers from here. A silent mismatch quietly degrades retrieval, so the
contract lives in exactly one place.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field

API_VERSION = "0.1.0"

# --- Embedding contract (AD-7, resolved via BLOCKER B-1) ----------------
# nomic-embed-code served through llama.cpp with `--embeddings --pooling last`.
# 3584 is the verified vector dimension; it permanently sets the Qdrant
# collection size. Changing the model => drop + re-index every collection.
EMBED_MODEL = "nomic-embed-code"
EMBED_DIM = 3584
DISTANCE = "Cosine"

# --- AD-10: prompt-prefix asymmetry (sacred contract) -------------------
QUERY_PREFIX = "Represent this query for searching relevant code: "
CODE_PREFIX = ""


def format_query(text: str) -> str:
    """Prefix a natural-language search query before embedding (AD-10)."""
    return f"{QUERY_PREFIX}{text}"


def format_code(text: str) -> str:
    """Code chunks are embedded with no prefix (AD-10)."""
    return f"{CODE_PREFIX}{text}"


# --- API schemas --------------------------------------------------------
class StatusResponse(BaseModel):
    status: str = "ok"
    api_version: str = API_VERSION
    embed_model: str = EMBED_MODEL
    embed_dim: int = EMBED_DIM
    qdrant_connected: bool


class LanguageStat(BaseModel):
    language: str
    files: int = 0
    chunks: int = 0


class RepoSummary(BaseModel):
    repo_id: str
    indexed_sha: str | None = None
    indexed_at: datetime | None = None
    chunk_count: int = 0


class RepoDetail(RepoSummary):
    file_count: int = 0
    skipped_count: int = 0
    languages: list[LanguageStat] = Field(default_factory=list)


class RepoStats(BaseModel):
    repo_id: str
    indexed_sha: str | None = None
    indexed_at: datetime | None = None
    file_count: int = 0
    chunk_count: int = 0
    skipped_count: int = 0
    languages: list[LanguageStat] = Field(default_factory=list)


class FileEntry(BaseModel):
    path: str
    language: str | None = None
    chunk_count: int = 0


class FilesResponse(BaseModel):
    repo_id: str
    total: int
    offset: int
    limit: int
    files: list[FileEntry]


class ErrorResponse(BaseModel):
    detail: str
