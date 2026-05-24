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

from pathlib import PurePosixPath
from typing import Protocol, runtime_checkable

import re

import httpx

from .models import EMBED_DIM, EMBED_MODEL, QueryHit, QueryResponse, format_query
from .registry import RegistryProtocol

TRIVIAL_FILE_NONBLANK_LINE_THRESHOLD = 2
TRIVIAL_NOISE_FILE_BASENAMES = {"__init__.py"}
OVERLAP_COLLAPSE_THRESHOLD = 0.5
OVERFETCH_FACTOR = 3

# Score bonus applied to a chunk whose ``symbol`` payload field matches a
# token from the user's query.  Definition chunks are ranked above chunks
# that merely reference the same identifier in their body text.
# Tunable: increase to push definitions higher; decrease if over-ranking.
DEFINITION_BOOST = 0.20


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

    @staticmethod
    def _tokenize_query(q: str) -> frozenset[str]:
        """Lower-case word tokens from a query string.

        Used to match against chunk ``symbol`` fields: if any token equals
        the declared symbol name (case-insensitive) the chunk receives the
        :data:`DEFINITION_BOOST` score bonus.
        """
        return frozenset(t.lower() for t in re.split(r"\W+", q) if t)

    @staticmethod
    def _nonblank_line_count(text: str) -> int:
        return sum(1 for line in text.splitlines() if line.strip())

    @staticmethod
    def _line_span(start_line: int, end_line: int) -> tuple[int, int]:
        start = int(start_line)
        end = int(end_line)
        if end < start:
            start, end = end, start
        return start, end

    @classmethod
    def _should_collapse(cls, a: QueryHit, b: QueryHit) -> bool:
        if a.path != b.path:
            return False
        a_start, a_end = cls._line_span(a.start_line, a.end_line)
        b_start, b_end = cls._line_span(b.start_line, b.end_line)

        overlap_start = max(a_start, b_start)
        overlap_end = min(a_end, b_end)
        if overlap_end < overlap_start:
            return False

        overlap = overlap_end - overlap_start + 1
        a_len = max(1, a_end - a_start + 1)
        b_len = max(1, b_end - b_start + 1)
        smaller = min(a_len, b_len)

        # Contains / nested ranges should always collapse.
        if (a_start <= b_start and a_end >= b_end) or (
            b_start <= a_start and b_end >= a_end
        ):
            return True
        return (overlap / smaller) > OVERLAP_COLLAPSE_THRESHOLD

    @classmethod
    def _post_process_hits(cls, hits: list[QueryHit], limit: int) -> list[QueryHit]:
        nonblank_by_path: dict[str, int] = {}
        for hit in hits:
            nonblank = cls._nonblank_line_count(hit.code)
            current = nonblank_by_path.get(hit.path, 0)
            if nonblank > current:
                nonblank_by_path[hit.path] = nonblank

        def is_trivial_noise_file(path: str) -> bool:
            if not path:
                return False
            basename = PurePosixPath(path).name
            return basename in TRIVIAL_NOISE_FILE_BASENAMES

        filtered = [
            hit
            for hit in hits
            if not (
                is_trivial_noise_file(hit.path)
                and nonblank_by_path.get(hit.path, 0)
                <= TRIVIAL_FILE_NONBLANK_LINE_THRESHOLD
            )
        ]

        collapsed: list[QueryHit] = []
        for hit in filtered:
            if any(cls._should_collapse(hit, kept) for kept in collapsed):
                continue
            collapsed.append(hit)
            if len(collapsed) >= limit:
                break
        return collapsed

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
            overfetch_limit = max(limit, limit * OVERFETCH_FACTOR)
            hits = client.query_points(
                repo_id, query=vector, limit=overfetch_limit, with_payload=True
            ).points
        except Exception:
            # Search is best-effort; never 500 a query path on a flaky
            # embedder/Qdrant — return what we have (possibly nothing).
            return response

        raw_results: list[QueryHit] = []
        query_tokens = self._tokenize_query(q)
        for h in hits:
            pl = getattr(h, "payload", None) or {}
            base_score = float(getattr(h, "score", 0.0))
            # Boost chunks whose declared symbol matches a query token so
            # definition sites outrank mere call sites (PR4 AD-high fix).
            symbol = pl.get("symbol")
            if symbol and symbol.lower() in query_tokens:
                score = base_score + DEFINITION_BOOST
            else:
                score = base_score
            raw_results.append(
                QueryHit(
                    path=pl.get("path", ""),
                    language=pl.get("language"),
                    start_line=int(pl.get("start_line", 0)),
                    end_line=int(pl.get("end_line", 0)),
                    code=pl.get("code", ""),
                    score=score,
                )
            )
        # Re-sort after boost: some definition chunks may have overtaken
        # call-site chunks that scored higher in the raw embedding search.
        raw_results.sort(key=lambda hit: hit.score, reverse=True)
        response.results = self._post_process_hits(raw_results, limit)
        return response
