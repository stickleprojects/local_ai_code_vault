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
from src.query_handler import (
    HttpQueryEmbedder,
    QueryHandler,
    TRIVIAL_FILE_NONBLANK_LINE_THRESHOLD,
)
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


def test_handler_filters_trivial_near_empty_files():
    fc = FakeClient(
        collections=["r1"],
        hits=[
            (
                {
                    "path": "pkg/__init__.py",
                    "start_line": 1,
                    "end_line": 1,
                    "code": "# marker\n",
                },
                0.99,
            ),
            (
                {
                    "path": "pkg/fixtures.py",
                    "start_line": 1,
                    "end_line": 6,
                    "code": "def make_session():\n    x = 1\n    return x\n",
                },
                0.75,
            ),
        ],
    )
    reg = FakeRegistry(repos={"r1": RepoDetail(repo_id="r1")}, client=fc)
    resp = QueryHandler(reg, FakeQueryEmbedder()).query("r1", "q", limit=5)
    assert resp is not None
    assert [h.path for h in resp.results] == ["pkg/fixtures.py"]
    assert (
        QueryHandler._nonblank_line_count("# marker\n")
        <= TRIVIAL_FILE_NONBLANK_LINE_THRESHOLD
    )


def test_handler_collapses_overlapping_ranges_to_preserve_distinct_hits():
    fc = FakeClient(
        collections=["r1"],
        hits=[
            (
                {
                    "path": "pkg/service.py",
                    "start_line": 10,
                    "end_line": 30,
                    "code": "class OrderService:\n    def publish(self):\n        return 1\n",
                },
                0.95,
            ),
            (
                {
                    "path": "pkg/service.py",
                    "start_line": 12,
                    "end_line": 18,
                    "code": "def publish(self):\n    return 1\n",
                },
                0.92,
            ),
            (
                {
                    "path": "tests/test_service.py",
                    "start_line": 1,
                    "end_line": 8,
                    "code": "def test_publish():\n    svc = 1\n    assert svc == 1\n",
                },
                0.60,
            ),
        ],
    )
    reg = FakeRegistry(repos={"r1": RepoDetail(repo_id="r1")}, client=fc)
    resp = QueryHandler(reg, FakeQueryEmbedder()).query("r1", "q", limit=2)
    assert resp is not None
    assert [h.path for h in resp.results] == ["pkg/service.py", "tests/test_service.py"]
    assert [(h.start_line, h.end_line) for h in resp.results] == [(10, 30), (1, 8)]


# ---------------------------------------------------------------------------
# Definition-boost tests — PR4 symbol-aware ranking.
# ---------------------------------------------------------------------------

def test_tokenize_query_basic():
    tokens = QueryHandler._tokenize_query("OrderService publish an order")
    assert "orderservice" in tokens
    assert "publish" in tokens
    assert "order" in tokens


def test_tokenize_query_empty():
    assert QueryHandler._tokenize_query("") == frozenset()


def test_definition_boost_raises_definition_above_callsite():
    """A definition chunk (symbol match) must outrank a call-site chunk
    even when the call-site chunk has a higher raw embedding score."""
    fc = FakeClient(
        collections=["r1"],
        hits=[
            # call-site chunk: high raw score, no symbol match
            (
                {
                    "path": "tests/test_service.py",
                    "start_line": 1,
                    "end_line": 30,
                    "code": "service = OrderService(repo)\nservice.publish(1)\n",
                },
                0.85,
            ),
            # definition chunk: lower raw score, but symbol == query token
            (
                {
                    "path": "pkg/service.py",
                    "start_line": 1,
                    "end_line": 20,
                    "code": "class OrderService:\n    def publish(self, order_id): ...\n",
                    "symbol": "OrderService",
                },
                0.75,
            ),
        ],
    )
    reg = FakeRegistry(repos={"r1": RepoDetail(repo_id="r1")}, client=fc)
    resp = QueryHandler(reg, FakeQueryEmbedder()).query(
        "r1", "OrderService publish an order implementation", limit=5
    )
    assert resp is not None
    paths = [h.path for h in resp.results]
    assert paths[0] == "pkg/service.py", (
        "Definition chunk must rank first after boost"
    )
    assert paths[1] == "tests/test_service.py"


def test_definition_boost_no_match_preserves_raw_order():
    """Chunks without a matching symbol must keep their original order."""
    fc = FakeClient(
        collections=["r1"],
        hits=[
            ({"path": "a.py", "start_line": 1, "end_line": 5, "code": "pass"}, 0.9),
            (
                {
                    "path": "b.py",
                    "start_line": 1,
                    "end_line": 5,
                    "code": "pass",
                    "symbol": "UnrelatedClass",
                },
                0.8,
            ),
        ],
    )
    reg = FakeRegistry(repos={"r1": RepoDetail(repo_id="r1")}, client=fc)
    resp = QueryHandler(reg, FakeQueryEmbedder()).query("r1", "some query", limit=5)
    assert resp is not None
    assert [h.path for h in resp.results] == ["a.py", "b.py"]


def test_definition_boost_csharp_symbol():
    """Boost is language-agnostic: C# symbol matches the same way as Python."""
    fc = FakeClient(
        collections=["r1"],
        hits=[
            (
                {
                    "path": "csharp/OrderServiceTests.cs",
                    "start_line": 1,
                    "end_line": 40,
                    "language": "csharp",
                    "code": "var svc = new OrderService(repo);\nsvc.Publish(1);\n",
                },
                0.88,
            ),
            (
                {
                    "path": "csharp/OrderService.cs",
                    "start_line": 1,
                    "end_line": 28,
                    "language": "csharp",
                    "code": "public class OrderService { public Order Publish(int id) { ... } }",
                    "symbol": "OrderService",
                },
                0.78,
            ),
        ],
    )
    reg = FakeRegistry(repos={"r1": RepoDetail(repo_id="r1")}, client=fc)
    resp = QueryHandler(reg, FakeQueryEmbedder()).query(
        "r1", "OrderService Publish an order implementation", limit=5
    )
    assert resp is not None
    assert resp.results[0].path == "csharp/OrderService.cs", (
        "C# definition must rank first after symbol boost"
    )

