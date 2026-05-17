"""Query path unit tests, incl. the AD-10 prefix contract.

The API-level tests use a fake embedder, so the *real* prefixing must
be locked here: ``HttpQueryEmbedder`` has to send the query with
``QUERY_PREFIX`` (the exact opposite of the indexer, which sends code
unprefixed — see tests/test_embedder.py). A regression here silently
halves retrieval quality.
"""

import json

import httpx
import pytest

from src.models import EMBED_DIM, QUERY_PREFIX
from src.query_handler import HttpQueryEmbedder, QueryHandler
from tests.fakes import FakeClient, FakeQueryEmbedder, FakeRegistry
from src.models import RepoDetail


def _server(dim: int, captured: list):
    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(json.loads(request.content))
        return httpx.Response(200, json={"data": [{"embedding": [0.2] * dim}]})

    return httpx.Client(transport=httpx.MockTransport(handler))


def test_http_query_embedder_applies_ad10_prefix():
    captured: list = []
    emb = HttpQueryEmbedder("http://e:8080", client=_server(EMBED_DIM, captured))
    vec = emb.embed_query("find the auth handler")
    assert len(vec) == EMBED_DIM
    sent = captured[0]["input"][0]
    assert sent == f"{QUERY_PREFIX}find the auth handler"
    assert sent.startswith(QUERY_PREFIX)


def test_http_query_embedder_dim_guard():
    emb = HttpQueryEmbedder("http://e:8080", client=_server(768, []))
    with pytest.raises(RuntimeError, match="pooling last"):
        emb.embed_query("x")


def test_handler_none_when_repo_unregistered():
    h = QueryHandler(FakeRegistry(), FakeQueryEmbedder())
    assert h.query("ghost", "q") is None


def test_handler_limit_is_passed_through():
    fc = FakeClient(
        collections=["r1"],
        hits=[({"path": f"f{i}.py", "start_line": 1, "end_line": 2,
                "code": "x"}, 1.0 - i / 10) for i in range(8)],
    )
    reg = FakeRegistry(repos={"r1": RepoDetail(repo_id="r1")}, client=fc)
    resp = QueryHandler(reg, FakeQueryEmbedder()).query("r1", "q", limit=3)
    assert resp is not None
    assert len(resp.results) == 3


def test_handler_swallows_search_failure():
    class Boom(FakeClient):
        def query_points(self, *a, **k):
            raise RuntimeError("qdrant down")

    reg = FakeRegistry(
        repos={"r1": RepoDetail(repo_id="r1")},
        client=Boom(collections=["r1"]),
    )
    resp = QueryHandler(reg, FakeQueryEmbedder()).query("r1", "q")
    assert resp is not None and resp.results == []
