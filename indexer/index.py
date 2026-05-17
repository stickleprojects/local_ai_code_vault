"""Ephemeral indexer entrypoint (Phase 1.2).

Run per job: ``docker run --rm ... indexer --repo-id <id> --qdrant-url
<u> --embedder-url <u> [--changed-files a,b]``. The container mounts the
host repo read-only at ``/repo``; nothing here ever writes to it.

It walks the repo, tree-sitter chunks supported files (C#/Py/JS/TS,
AD-8), embeds chunks via the shared llama.cpp server (B-1/AD-5), upserts
them into the Qdrant collection named ``repo_id``, then writes the repo's
row into the ``__vault_registry__`` collection. That registry write *is*
registration — Phase 1.1's API only ever reads it, so the payload shape
here is the producer side of a contract with ``src/registry.py`` and
``src/inspection.py`` (guarded by a round-trip test).

``run_index`` is pure orchestration with injected embedder/writer so the
whole flow is unit-testable offline (CI: in-memory fakes, no services).
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Protocol, runtime_checkable

from .chunker import MAX_FILE_BYTES, Chunk, chunk_source, language_for
from .embedder import EmbedderProtocol, HttpEmbedder

REGISTRY_COLLECTION = "__vault_registry__"
_ID_NAMESPACE = uuid.UUID("6ba7b811-9dad-11d1-80b4-00c04fd430c8")  # stable

# Directories never worth indexing; pruned during the walk.
_IGNORE_DIRS = {
    ".git",
    "node_modules",
    ".venv",
    "venv",
    "__pycache__",
    ".mypy_cache",
    ".pytest_cache",
    ".tox",
    "dist",
    "build",
    ".idea",
    ".vscode",
}


@dataclass
class ChunkPoint:
    id: str
    vector: list[float]
    payload: dict


@dataclass
class RegistryPoint:
    id: str
    payload: dict


@dataclass
class CollectionStats:
    file_count: int = 0
    chunk_count: int = 0
    # language -> {"files": int, "chunks": int}
    languages: dict[str, dict[str, int]] = field(default_factory=dict)


@runtime_checkable
class WriterProtocol(Protocol):
    """Qdrant write surface (lets tests inject an in-memory fake)."""

    def ensure_collection(self, name: str, dim: int, *, recreate: bool) -> None: ...
    def delete_by_paths(self, collection: str, paths: list[str]) -> None: ...
    def upsert_chunks(self, collection: str, points: list[ChunkPoint]) -> None: ...
    def collection_stats(self, collection: str) -> CollectionStats: ...
    def ensure_registry(self) -> None: ...
    def upsert_registry(self, point: RegistryPoint) -> None: ...


@dataclass
class IndexResult:
    repo_id: str
    indexed_sha: str | None
    indexed_at: str
    file_count: int
    chunk_count: int
    skipped_count: int
    languages: list[dict]
    incremental: bool


def _point_id(repo_id: str, path: str, start_byte: int, end_byte: int) -> str:
    # Byte offsets, not line numbers: several declarations can share a
    # line (single-line/minified C#), and ids must stay collision-free.
    return str(
        uuid.uuid5(_ID_NAMESPACE, f"{repo_id}:{path}:{start_byte}:{end_byte}")
    )


def _is_binary(data: bytes) -> bool:
    return b"\x00" in data[:8192]


def _rel(path: str) -> str:
    return path.replace(os.sep, "/")


def compute_head_sha(repo_path: str) -> str | None:
    """Best-effort HEAD SHA; ``None`` if not a git repo / git absent."""
    try:
        out = subprocess.run(
            ["git", "-C", repo_path, "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return out.stdout.strip() or None if out.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def _walk_files(repo_path: str) -> list[str]:
    """Repo-relative POSIX paths of every file, ignored dirs pruned."""
    found: list[str] = []
    for root, dirs, files in os.walk(repo_path):
        dirs[:] = [
            d for d in dirs if d not in _IGNORE_DIRS and not d.startswith(".")
        ]
        for name in files:
            abs_path = os.path.join(root, name)
            found.append(_rel(os.path.relpath(abs_path, repo_path)))
    return found


def run_index(
    repo_path: str,
    repo_id: str,
    embedder: EmbedderProtocol,
    writer: WriterProtocol,
    *,
    head_sha: str | None,
    changed_files: list[str] | None = None,
    embed_dim: int,
) -> IndexResult:
    """Chunk → embed → upsert one repo, then write its registry row.

    Full run (``changed_files is None``) recreates the collection so
    deleted files don't linger. Incremental run touches only the named
    files: their old chunks are deleted first (covers deletions), then
    surviving files are re-chunked and upserted. Registry counts are
    always recomputed from the *resulting* collection, so they stay
    truthful in both modes.
    """
    incremental = changed_files is not None

    if incremental:
        candidates = [_rel(p) for p in changed_files or []]
    else:
        candidates = _walk_files(repo_path)

    chunks: list[Chunk] = []
    skipped = 0

    for rel in candidates:
        language = language_for(rel)
        if language is None:
            skipped += 1  # unsupported language (AD-9 visibility)
            continue
        abs_path = os.path.join(repo_path, rel.replace("/", os.sep))
        if not os.path.isfile(abs_path):
            # Incremental: a deleted/renamed file. Its stale chunks are
            # cleared by delete_by_paths below; nothing to re-add.
            continue
        try:
            if os.path.getsize(abs_path) > MAX_FILE_BYTES:
                skipped += 1
                continue
            with open(abs_path, "rb") as fh:
                data = fh.read()
        except OSError:
            skipped += 1
            continue
        if _is_binary(data):
            skipped += 1
            continue
        chunks.extend(chunk_source(rel, data, language))

    collection = repo_id
    writer.ensure_collection(collection, embed_dim, recreate=not incremental)

    if incremental:
        writer.delete_by_paths(collection, candidates)

    if chunks:
        vectors = embedder.embed([c.text for c in chunks])
        points = [
            ChunkPoint(
                id=_point_id(repo_id, c.path, c.start_byte, c.end_byte),
                vector=vec,
                payload={
                    "repo_id": repo_id,
                    "path": c.path,
                    "language": c.language,
                    "start_line": c.start_line,
                    "end_line": c.end_line,
                    "code": c.text,
                },
            )
            for c, vec in zip(chunks, vectors)
        ]
        writer.upsert_chunks(collection, points)

    stats = writer.collection_stats(collection)
    languages = [
        {"language": lang, "files": v["files"], "chunks": v["chunks"]}
        for lang, v in sorted(stats.languages.items())
    ]
    indexed_at = datetime.now(timezone.utc).isoformat()

    writer.ensure_registry()
    writer.upsert_registry(
        RegistryPoint(
            id=str(uuid.uuid5(_ID_NAMESPACE, repo_id)),
            payload={
                "repo_id": repo_id,
                "indexed_sha": head_sha,
                "indexed_at": indexed_at,
                "chunk_count": stats.chunk_count,
                "file_count": stats.file_count,
                "skipped_count": skipped,
                "languages": languages,
            },
        )
    )

    return IndexResult(
        repo_id=repo_id,
        indexed_sha=head_sha,
        indexed_at=indexed_at,
        file_count=stats.file_count,
        chunk_count=stats.chunk_count,
        skipped_count=skipped,
        languages=languages,
        incremental=incremental,
    )


def _parse_changed(raw: str | None) -> list[str] | None:
    if raw is None:
        return None
    return [p.strip() for p in raw.split(",") if p.strip()]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="indexer", description=__doc__)
    parser.add_argument("--repo-id", required=True)
    parser.add_argument("--repo-path", default=os.environ.get("REPO_PATH", "/repo"))
    parser.add_argument(
        "--qdrant-url",
        default=os.environ.get("QDRANT_URL", "http://qdrant:6333"),
    )
    parser.add_argument(
        "--embedder-url",
        default=os.environ.get("EMBEDDER_URL", "http://embedder:8080"),
    )
    parser.add_argument(
        "--changed-files",
        default=None,
        help="comma-separated repo-relative paths; enables incremental mode",
    )
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    def log(msg: str) -> None:
        if args.verbose:
            print(f"[indexer] {msg}", file=sys.stderr)

    # Imported lazily so the module stays import-safe without qdrant_client.
    from .qdrant_writer import QdrantWriter
    from src.models import EMBED_DIM

    embedder = HttpEmbedder(args.embedder_url)
    writer = QdrantWriter(args.qdrant_url)
    head_sha = compute_head_sha(args.repo_path)
    log(f"repo_id={args.repo_id} sha={head_sha} path={args.repo_path}")

    result = run_index(
        args.repo_path,
        args.repo_id,
        embedder,
        writer,
        head_sha=head_sha,
        changed_files=_parse_changed(args.changed_files),
        embed_dim=EMBED_DIM,
    )
    # Machine-readable summary on stdout for the Phase 2 launcher script.
    print(
        '{{"repo_id": "{r}", "files": {f}, "chunks": {c}, "skipped": {s}, '
        '"sha": {sha}, "incremental": {inc}}}'.format(
            r=result.repo_id,
            f=result.file_count,
            c=result.chunk_count,
            s=result.skipped_count,
            sha=f'"{result.indexed_sha}"' if result.indexed_sha else "null",
            inc="true" if result.incremental else "false",
        )
    )
    log("done")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
