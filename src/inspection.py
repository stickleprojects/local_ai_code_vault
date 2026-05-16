"""AD-9: read-only introspection of what has been indexed.

Distinct from semantic search. ``stats`` summarises a repo's index
(counts + per-language breakdown + skipped files) from the registry
metadata. ``files`` lists the indexed file inventory by aggregating the
repo's own Qdrant collection points by file path.

In Phase 1.1 there is no indexer yet, so a registered repo with no
collection simply yields an empty file inventory rather than an error.
"""

from __future__ import annotations

from .models import FileEntry, FilesResponse, RepoStats
from .registry import QdrantRegistry


class Inspector:
    def __init__(self, registry: QdrantRegistry):
        self.registry = registry

    def stats(self, repo_id: str) -> RepoStats | None:
        repo = self.registry.get_repo(repo_id)
        if repo is None:
            return None
        return RepoStats(
            repo_id=repo.repo_id,
            indexed_sha=repo.indexed_sha,
            indexed_at=repo.indexed_at,
            file_count=repo.file_count,
            chunk_count=repo.chunk_count,
            skipped_count=repo.skipped_count,
            languages=repo.languages,
        )

    def files(self, repo_id: str, offset: int, limit: int) -> FilesResponse | None:
        repo = self.registry.get_repo(repo_id)
        if repo is None:
            return None

        agg: dict[str, dict] = {}
        client = self.registry.client
        try:
            collections = {c.name for c in client.get_collections().collections}
            if repo_id in collections:
                next_off = None
                while True:
                    points, next_off = client.scroll(
                        repo_id, with_payload=True, limit=256, offset=next_off
                    )
                    for p in points:
                        pl = p.payload or {}
                        path = pl.get("path") or pl.get("file")
                        if not path:
                            continue
                        entry = agg.setdefault(
                            path, {"language": pl.get("language"), "chunk_count": 0}
                        )
                        entry["chunk_count"] += 1
                    if next_off is None:
                        break
        except Exception:
            # Inventory is best-effort; registry metadata is authoritative.
            pass

        all_files = [
            FileEntry(path=k, language=v["language"], chunk_count=v["chunk_count"])
            for k, v in sorted(agg.items())
        ]
        return FilesResponse(
            repo_id=repo_id,
            total=len(all_files),
            offset=offset,
            limit=limit,
            files=all_files[offset : offset + limit],
        )
