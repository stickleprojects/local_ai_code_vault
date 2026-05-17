"""In-memory fakes for the indexer (no Qdrant / embedder needed).

``FakeWriter`` implements ``WriterProtocol`` against a dict store and
computes ``collection_stats`` the same way the real ``QdrantWriter``
does, so orchestration tests exercise the true counting logic. Its
``as_fake_client()`` adapts the registry write into the same
``FakeClient`` shape ``src.registry`` reads — that adapter is what lets
the round-trip contract test prove producer/consumer agreement.
"""

from __future__ import annotations

from types import SimpleNamespace

from indexer.index import (
    ChunkPoint,
    CollectionStats,
    RegistryPoint,
    WriterProtocol,
)


class FakeEmbedder:
    """Deterministic fixed-dimension vectors; records what it embedded."""

    def __init__(self, dim: int):
        self.dim = dim
        self.seen: list[str] = []

    def embed(self, texts: list[str]) -> list[list[float]]:
        self.seen.extend(texts)
        return [[float(len(t) % 7)] * self.dim for t in texts]


class FakeWriter(WriterProtocol):
    def __init__(self) -> None:
        # collection -> {point_id: payload}
        self.collections: dict[str, dict[str, dict]] = {}
        self.registry: dict[str, dict] = {}
        self.recreated: list[str] = []

    def ensure_collection(self, name: str, dim: int, *, recreate: bool) -> None:
        if recreate or name not in self.collections:
            self.collections[name] = {}
            if recreate:
                self.recreated.append(name)

    def delete_by_paths(self, collection: str, paths: list[str]) -> None:
        store = self.collections.get(collection, {})
        wanted = set(paths)
        for pid in [k for k, v in store.items() if v.get("path") in wanted]:
            del store[pid]

    def upsert_chunks(self, collection: str, points: list[ChunkPoint]) -> None:
        store = self.collections.setdefault(collection, {})
        for p in points:
            store[p.id] = p.payload

    def collection_stats(self, collection: str) -> CollectionStats:
        stats = CollectionStats()
        store = self.collections.get(collection, {})
        seen_files: set[str] = set()
        lang_files: dict[str, set[str]] = {}
        for pl in store.values():
            path = pl.get("path")
            lang = pl.get("language", "unknown")
            stats.chunk_count += 1
            stats.languages.setdefault(lang, {"files": 0, "chunks": 0})
            stats.languages[lang]["chunks"] += 1
            if path:
                seen_files.add(path)
                lang_files.setdefault(lang, set()).add(path)
        stats.file_count = len(seen_files)
        for lang, files in lang_files.items():
            stats.languages[lang]["files"] = len(files)
        return stats

    def ensure_registry(self) -> None:
        self.collections.setdefault("__vault_registry__", {})

    def upsert_registry(self, point: RegistryPoint) -> None:
        self.registry[point.id] = point.payload

    # --- bridge to the Phase 1.1 read side ------------------------------
    def as_fake_client(self):
        """A ``src.registry``-compatible client over the written rows."""
        points = [
            SimpleNamespace(id=pid, payload=pl)
            for pid, pl in self.registry.items()
        ]

        class _Client:
            def __init__(self, names, pts):
                self._names = names
                self._pts = pts

            def get_collections(self):
                return SimpleNamespace(
                    collections=[SimpleNamespace(name=n) for n in self._names]
                )

            def scroll(self, name, with_payload=True, limit=128,
                       offset=None, scroll_filter=None, with_vectors=None):
                return self._pts, None

        return _Client({"__vault_registry__"}, points)
