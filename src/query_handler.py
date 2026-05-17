"""Phase 1.3: semantic query over a repo's Qdrant collection.

Pipeline: embed the natural-language query → vector-search the repo's
collection → return ranked ``(path, lines, code, score)`` for Claude.

AD-10 is the sacred contract and the *whole point* of this file living
apart from the indexer: the query path **must** prefix the text with
:data:`src.models.QUERY_PREFIX` (via :func:`format_query`), whereas the
indexer embeds code with no prefix. A mismatch silently wrecks ranking,
so the prefix is applied here in exactly one place and asserted in tests.

``src`` deliberately does not import from ``indexer`` (that package
depends on ``src``); the ~10 lines of query-side embedding HTTP are kept
local rather than invert that layering.
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

import httpx

from .models import EMBED_DIM, EMBED_MODEL, QueryHit, QueryResponse, format_query
from .registry import RegistryProtocol


@runtime_checkable
class QueryEmbedderProtocol(Protocol):
    """Embeds a *query* (lets tests inject a fake)."""

    def embed_query(self, text: str) -> list[float]: ...


class HttpQueryEmbedder:
    """Query-side client for the shared llama.cpp embeddings server."""

    def __init__(
        self, url: str, *, timeout: float = 30.0, client: httpx.Client | None = None
    ):
        self._url = url.rstrip("/")
        self._timeout = timeout
        self._client = client

    @property
    def client(self) -> httpx.Client:
        if self._client is None:
            self._client = httpx.Client(timeout=self._timeout)
        return self._client

    def embed_query(self, text: str) -> list[float]:
        # AD-10: queries MUST carry the prefix. One place, here.
        payload = {"model": EMBED_MODEL, "input": [format_query(text)]}
        resp = self.client.post(f"{self._url}/v1/embeddings", json=payload)
        resp.raise_for_status()
        vec = resp.json()["data"][0]["embedding"]
        if len(vec) != EMBED_DIM:
            raise RuntimeError(
                f"embedder returned dim {len(vec)}, expected {EMBED_DIM} "
                "— server likely lost `--pooling last` (B-1 failure mode)"
            )
        return vec


class QueryHandler:
    """Resolve a query against one registered repo's collection.

    Returns ``None`` when the repo isn't registered (API → 404). A
    registered repo whose collection is empty/absent yields an empty
    result list rather than an error.
    """

    def __init__(self, registry: RegistryProtocol, embedder: QueryEmbedderProtocol):
        self.registry = registry
        self.embedder = embedder

    def query(self, repo_id: str, q: str, limit: int = 10) -> QueryResponse | None:
        if self.registry.get_repo(repo_id) is None:
            return None

        response = QueryResponse(repo_id=repo_id, query=q, results=[])

        client = self.registry.client
        try:
            collections = {c.name for c in client.get_collections().collections}
            if repo_id not in collections:
                return response  # registered but nothing indexed yet
            vector = self.embedder.embed_query(q)
            hits = client.query_points(
                repo_id, query=vector, limit=limit, with_payload=True
            ).points
        except Exception:
            # Search is best-effort; never 500 a query path on a flaky
            # embedder/Qdrant — return what we have (possibly nothing).
            return response

        for h in hits:
            pl = getattr(h, "payload", None) or {}
            response.results.append(
                QueryHit(
                    path=pl.get("path", ""),
                    language=pl.get("language"),
                    start_line=int(pl.get("start_line", 0)),
                    end_line=int(pl.get("end_line", 0)),
                    code=pl.get("code", ""),
                    score=float(getattr(h, "score", 0.0)),
                )
            )
        return response
