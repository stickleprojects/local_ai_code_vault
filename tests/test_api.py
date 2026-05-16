from datetime import datetime, timezone

from fastapi.testclient import TestClient

from src.app import create_app
from src.models import LanguageStat, RepoDetail
from tests.fakes import FakeRegistry


def client(registry) -> TestClient:
    return TestClient(create_app(registry=registry))


def test_status_ok_qdrant_down():
    c = client(FakeRegistry(connected=False))
    r = c.get("/api/status")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["embed_dim"] == 3584
    assert body["embed_model"] == "nomic-embed-code"
    assert body["qdrant_connected"] is False


def test_repos_empty_on_fresh_stack():
    # Phase 1.1 acceptance: [] before anything is indexed.
    r = client(FakeRegistry()).get("/api/repos")
    assert r.status_code == 200
    assert r.json() == []


def test_unregistered_repo_is_404():
    c = client(FakeRegistry())
    assert c.get("/api/repos/nope").status_code == 404
    assert c.get("/api/repos/nope/stats").status_code == 404
    assert c.get("/api/repos/nope/files").status_code == 404


def test_query_is_501_until_phase_1_3():
    r = client(FakeRegistry()).get("/api/query/anything", params={"q": "find auth"})
    assert r.status_code == 501


def test_registered_repo_surface():
    repo = RepoDetail(
        repo_id="proj-abcd1234",
        indexed_sha="deadbeef",
        indexed_at=datetime(2026, 5, 16, tzinfo=timezone.utc),
        chunk_count=42,
        file_count=7,
        skipped_count=3,
        languages=[
            LanguageStat(language="python", files=5, chunks=30),
            LanguageStat(language="csharp", files=2, chunks=12),
        ],
    )
    c = client(FakeRegistry(connected=True, repos={"proj-abcd1234": repo}))

    assert [x["repo_id"] for x in c.get("/api/repos").json()] == ["proj-abcd1234"]

    detail = c.get("/api/repos/proj-abcd1234").json()
    assert detail["chunk_count"] == 42
    assert len(detail["languages"]) == 2

    stats = c.get("/api/repos/proj-abcd1234/stats").json()
    assert stats["file_count"] == 7
    assert stats["skipped_count"] == 3
    assert {l["language"] for l in stats["languages"]} == {"python", "csharp"}

    files = c.get("/api/repos/proj-abcd1234/files").json()
    assert files["repo_id"] == "proj-abcd1234"
    assert files["total"] == 0  # registered but no collection yet (no indexer in 1.1)
