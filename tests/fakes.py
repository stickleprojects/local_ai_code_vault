"""In-memory fakes so the API surface is testable without a live Qdrant.

`FakeRegistry` satisfies the same interface the API depends on
(`RegistryProtocol`) and exposes a `client` attribute good enough for the
`Inspector` file-inventory path.
"""

from __future__ import annotations

from types import SimpleNamespace

from src.models import RepoDetail, RepoSummary


class FakeClient:
    def __init__(self, collections=None, points=None):
        self._collections = collections or []
        self._points = points or []

    def get_collections(self):
        return SimpleNamespace(
            collections=[SimpleNamespace(name=n) for n in self._collections]
        )

    def scroll(self, name, with_payload=True, limit=256, offset=None, scroll_filter=None):
        return self._points, None


class FakeRegistry:
    def __init__(self, connected: bool = False, repos: dict[str, RepoDetail] | None = None):
        self._connected = connected
        self._repos: dict[str, RepoDetail] = repos or {}
        self.client = FakeClient()

    def is_connected(self) -> bool:
        return self._connected

    def list_repos(self) -> list[RepoSummary]:
        return [
            RepoSummary(
                repo_id=r.repo_id,
                indexed_sha=r.indexed_sha,
                indexed_at=r.indexed_at,
                chunk_count=r.chunk_count,
            )
            for r in sorted(self._repos.values(), key=lambda x: x.repo_id)
        ]

    def get_repo(self, repo_id: str) -> RepoDetail | None:
        return self._repos.get(repo_id)
