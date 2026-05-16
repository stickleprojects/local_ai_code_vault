"""Repo registry backed by a reserved Qdrant collection.

Registration is *implicit* (AD: "a repo becomes registered when the
indexer first writes its collection + metadata"). The future ephemeral
indexer upserts one point per repo into ``REGISTRY_COLLECTION`` with the
repo metadata in the payload (indexed SHA, timestamp, per-language stats,
counts).

Phase 1.1 only *reads* this. On a fresh stack the registry collection
does not exist yet, so ``list_repos()`` returns ``[]`` — exactly the
Phase 1.1 acceptance criterion. The API never fails to start just
because Qdrant is down; ``/api/status`` reports connectivity instead.
"""

from __future__ import annotations

import os
from typing import Protocol, runtime_checkable

from qdrant_client import QdrantClient
from qdrant_client import models as qm

from .models import LanguageStat, RepoDetail, RepoSummary

REGISTRY_COLLECTION = "__vault_registry__"
DEFAULT_QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6333")


@runtime_checkable
class RegistryProtocol(Protocol):
    """Interface the API depends on (lets tests inject a fake)."""

    def is_connected(self) -> bool: ...
    def list_repos(self) -> list[RepoSummary]: ...
    def get_repo(self, repo_id: str) -> RepoDetail | None: ...


def _eq_filter(key: str, value: str) -> qm.Filter:
    return qm.Filter(must=[qm.FieldCondition(key=key, match=qm.MatchValue(value=value))])


def _to_languages(raw) -> list[LanguageStat]:
    out: list[LanguageStat] = []
    for item in raw or []:
        out.append(
            LanguageStat(
                language=item.get("language", "unknown"),
                files=int(item.get("files", 0)),
                chunks=int(item.get("chunks", 0)),
            )
        )
    return out


class QdrantRegistry:
    """Read-side of the repo registry over Qdrant."""

    def __init__(self, url: str | None = None, client: QdrantClient | None = None):
        self._url = url or DEFAULT_QDRANT_URL
        self._client = client

    @property
    def client(self) -> QdrantClient:
        if self._client is None:
            self._client = QdrantClient(url=self._url, timeout=5.0)
        return self._client

    def is_connected(self) -> bool:
        try:
            self.client.get_collections()
            return True
        except Exception:
            return False

    def _collection_names(self) -> set[str]:
        try:
            return {c.name for c in self.client.get_collections().collections}
        except Exception:
            return set()

    def list_repos(self) -> list[RepoSummary]:
        if REGISTRY_COLLECTION not in self._collection_names():
            return []
        repos: list[RepoSummary] = []
        offset = None
        while True:
            points, offset = self.client.scroll(
                REGISTRY_COLLECTION, with_payload=True, limit=128, offset=offset
            )
            for p in points:
                pl = p.payload or {}
                repos.append(
                    RepoSummary(
                        repo_id=pl.get("repo_id", str(p.id)),
                        indexed_sha=pl.get("indexed_sha"),
                        indexed_at=pl.get("indexed_at"),
                        chunk_count=int(pl.get("chunk_count", 0)),
                    )
                )
            if offset is None:
                break
        return sorted(repos, key=lambda r: r.repo_id)

    def get_repo(self, repo_id: str) -> RepoDetail | None:
        if REGISTRY_COLLECTION not in self._collection_names():
            return None
        points, _ = self.client.scroll(
            REGISTRY_COLLECTION,
            with_payload=True,
            limit=1,
            scroll_filter=_eq_filter("repo_id", repo_id),
        )
        if not points:
            return None
        pl = points[0].payload or {}
        return RepoDetail(
            repo_id=pl.get("repo_id", repo_id),
            indexed_sha=pl.get("indexed_sha"),
            indexed_at=pl.get("indexed_at"),
            chunk_count=int(pl.get("chunk_count", 0)),
            file_count=int(pl.get("file_count", 0)),
            skipped_count=int(pl.get("skipped_count", 0)),
            languages=_to_languages(pl.get("languages")),
        )
