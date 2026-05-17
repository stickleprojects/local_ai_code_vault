"""Embedding client for the shared llama.cpp server (B-1 / AD-5).

The server runs ``--embeddings --pooling last`` and exposes the
OpenAI-compatible ``POST /v1/embeddings``. Code chunks are routed
through :func:`src.models.format_code` — AD-10's sacred contract: code
gets *no* prefix, queries do. Going through the shared helper (rather
than embedding raw here) keeps the indexer and the query path provably
on the same side of the contract; a silent mismatch quietly wrecks
retrieval.

Every returned vector is asserted to be exactly ``EMBED_DIM`` (3584).
A wrong dimension means the server lost its ``--pooling last`` flag
(the original B-1 failure mode) — fail loud, don't poison the index.
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

import httpx

from src.models import EMBED_DIM, EMBED_MODEL, format_code


@runtime_checkable
class EmbedderProtocol(Protocol):
    """Interface the indexer depends on (lets tests inject a fake)."""

    def embed(self, texts: list[str]) -> list[list[float]]: ...


class HttpEmbedder:
    """Talks to the warm llama.cpp embeddings server over HTTP."""

    def __init__(
        self,
        url: str,
        *,
        batch_size: int = 32,
        timeout: float = 120.0,
        client: httpx.Client | None = None,
    ):
        self._url = url.rstrip("/")
        self._batch_size = batch_size
        self._timeout = timeout
        self._client = client

    @property
    def client(self) -> httpx.Client:
        if self._client is None:
            self._client = httpx.Client(timeout=self._timeout)
        return self._client

    def _embed_batch(self, batch: list[str]) -> list[list[float]]:
        # AD-10: code is embedded with no prefix, via the shared helper.
        payload = {"model": EMBED_MODEL, "input": [format_code(t) for t in batch]}
        resp = self.client.post(f"{self._url}/v1/embeddings", json=payload)
        resp.raise_for_status()
        data = resp.json().get("data", [])
        if len(data) != len(batch):
            raise RuntimeError(
                f"embedder returned {len(data)} vectors for {len(batch)} inputs"
            )
        vectors: list[list[float]] = []
        for item in data:
            vec = item["embedding"]
            if len(vec) != EMBED_DIM:
                raise RuntimeError(
                    f"embedder returned dim {len(vec)}, expected {EMBED_DIM} "
                    "— server likely lost `--pooling last` (B-1 failure mode)"
                )
            vectors.append(vec)
        return vectors

    def embed(self, texts: list[str]) -> list[list[float]]:
        out: list[list[float]] = []
        for i in range(0, len(texts), self._batch_size):
            out.extend(self._embed_batch(texts[i : i + self._batch_size]))
        return out
