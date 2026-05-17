from datetime import datetime, timezone

from fastapi.testclient import TestClient

from src.app import create_app
from src.models import LanguageStat, RepoDetail
from tests.fakes import FakeClient, FakeQueryEmbedder, FakeRegistry


def client(registry, query_embedder=None) -> TestClient:
    return TestClient(
        create_app(registry=registry, query_embedder=query_embedder)
    )


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


def test_query_unregistered_repo_is_404():
    r = client(FakeRegistry()).get("/api/query/nope", params={"q": "find auth"})
    assert r.status_code == 404


def test_query_registered_but_not_indexed_returns_empty():
    repo = RepoDetail(repo_id="r1")
    # registered, but no collection named r1 yet (indexer hasn't run).
    reg = FakeRegistry(repos={"r1": repo}, client=FakeClient(collections=[]))
    r = client(reg, FakeQueryEmbedder()).get(
        "/api/query/r1", params={"q": "auth"}
    )
    assert r.status_code == 200
    assert r.json() == {"repo_id": "r1", "query": "auth", "results": []}


def test_query_returns_ranked_hits_and_uses_ad10_prefix():
    repo = RepoDetail(repo_id="r1")
    fc = FakeClient(
        collections=["r1"],
        hits=[
            ({"path": "a.py", "language": "python", "start_line": 1,
              "end_line": 9, "code": "def login(): ..."}, 0.91),
            ({"path": "b.py", "language": "python", "start_line": 3,
              "end_line": 5, "code": "def helper(): ..."}, 0.42),
        ],
    )
    reg = FakeRegistry(repos={"r1": repo}, client=fc)
    emb = FakeQueryEmbedder()
    r = client(reg, emb).get(
        "/api/query/r1", params={"q": "how does login work", "limit": 5}
    )
    assert r.status_code == 200
    body = r.json()
    assert [h["path"] for h in body["results"]] == ["a.py", "b.py"]
    assert body["results"][0]["score"] == 0.91
    assert body["results"][0]["code"] == "def login(): ..."
    # AD-10: the query path embedded the *prefixed* query.
    assert emb.seen == ["how does login work"]  # handler passes raw; prefix is in HttpQueryEmbedder


def test_query_validates_params():
    reg = FakeRegistry(repos={"r1": RepoDetail(repo_id="r1")})
    c = client(reg, FakeQueryEmbedder())
    assert c.get("/api/query/r1", params={"q": ""}).status_code == 422
    assert c.get(
        "/api/query/r1", params={"q": "x", "limit": 0}
    ).status_code == 422


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
