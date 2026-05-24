"""Real Qdrant write surface for the indexer (:class:`WriterProtocol`).

Mirrors the read-side pattern in ``src/registry.py``: a thin, injectable
class with a lazy client so ``indexer.index`` stays import-safe and
unit-testable without ``qdrant_client`` or a live Qdrant.

Registry rows live in ``__vault_registry__`` as payload-only points
(dummy 1-d vector — the read side only ``scroll``s, never searches it).
Per-repo chunk collections are sized to the embedding contract
(``EMBED_DIM`` = 3584, cosine) per AD-7/B-1.
"""

from __future__ import annotations

from qdrant_client import QdrantClient
from qdrant_client import models as qm

from .index import ChunkPoint, CollectionStats, RegistryPoint, WriterProtocol

REGISTRY_COLLECTION = "__vault_registry__"
UPSERT_BATCH_SIZE = 128


class QdrantWriter(WriterProtocol):
    def __init__(self, url: str, client: QdrantClient | None = None):
        self._url = url
        self._client = client

    @property
    def client(self) -> QdrantClient:
        if self._client is None:
            self._client = QdrantClient(url=self._url, timeout=120.0)
        return self._client

    def _names(self) -> set[str]:
        return {c.name for c in self.client.get_collections().collections}

    def ensure_collection(self, name: str, dim: int, *, recreate: bool) -> None:
        exists = name in self._names()
        if exists and recreate:
            self.client.delete_collection(name)
            exists = False
        if not exists:
            self.client.create_collection(
                name,
                vectors_config=qm.VectorParams(
                    size=dim, distance=qm.Distance.COSINE
                ),
            )

    def delete_by_paths(self, collection: str, paths: list[str]) -> None:
        if not paths or collection not in self._names():
            return
        self.client.delete(
            collection,
            points_selector=qm.FilterSelector(
                filter=qm.Filter(
                    must=[
                        qm.FieldCondition(
                            key="path", match=qm.MatchAny(any=list(paths))
                        )
                    ]
                )
            ),
        )

    def upsert_chunks(self, collection: str, points: list[ChunkPoint]) -> None:
        if not points:
            return
        for i in range(0, len(points), UPSERT_BATCH_SIZE):
            batch = points[i : i + UPSERT_BATCH_SIZE]
            self.client.upsert(
                collection,
                points=[
                    qm.PointStruct(id=p.id, vector=p.vector, payload=p.payload)
                    for p in batch
                ],
                wait=True,
            )

    def collection_stats(self, collection: str) -> CollectionStats:
        stats = CollectionStats()
        if collection not in self._names():
            return stats
        seen_files: set[str] = set()
        lang_files: dict[str, set[str]] = {}
        offset = None
        while True:
            rows, offset = self.client.scroll(
                collection,
                with_payload=True,
                with_vectors=False,
                limit=256,
                offset=offset,
            )
            for r in rows:
                pl = r.payload or {}
                path = pl.get("path")
                lang = pl.get("language", "unknown")
                stats.chunk_count += 1
                bucket = stats.languages.setdefault(
                    lang, {"files": 0, "chunks": 0}
                )
                bucket["chunks"] += 1
                if path and path not in seen_files:
                    seen_files.add(path)
                if path:
                    lang_files.setdefault(lang, set()).add(path)
            if offset is None:
                break
        stats.file_count = len(seen_files)
        for lang, files in lang_files.items():
            stats.languages[lang]["files"] = len(files)
        return stats

    def ensure_registry(self) -> None:
        if REGISTRY_COLLECTION not in self._names():
            self.client.create_collection(
                REGISTRY_COLLECTION,
                vectors_config=qm.VectorParams(
                    size=1, distance=qm.Distance.COSINE
                ),
            )

    def upsert_registry(self, point: RegistryPoint) -> None:
        self.client.upsert(
            REGISTRY_COLLECTION,
            points=[
                qm.PointStruct(id=point.id, vector=[0.0], payload=point.payload)
            ],
        )
