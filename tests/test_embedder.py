import json

import httpx
import pytest

from indexer.embedder import HttpEmbedder
from src.models import EMBED_DIM, QUERY_PREFIX


def _server(dim: int, *, captured: list):
    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        captured.append(body)
        return httpx.Response(
            200,
            json={"data": [{"embedding": [0.1] * dim} for _ in body["input"]]},
        )

    return httpx.Client(transport=httpx.MockTransport(handler))


def test_embeds_with_no_prefix_for_code_ad10():
    captured: list = []
    emb = HttpEmbedder(
        "http://embedder:8080", client=_server(EMBED_DIM, captured=captured)
    )
    out = emb.embed(["def f(): pass", "class C: ..."])
    assert len(out) == 2
    assert all(len(v) == EMBED_DIM for v in out)
    # AD-10 sacred contract: code is sent verbatim, never query-prefixed.
    sent = captured[0]["input"]
    assert sent == ["def f(): pass", "class C: ..."]
    assert not any(s.startswith(QUERY_PREFIX) for s in sent)


def test_batches_requests():
    captured: list = []
    emb = HttpEmbedder(
        "http://e:8080",
        batch_size=2,
        client=_server(EMBED_DIM, captured=captured),
    )
    out = emb.embed(["a", "b", "c", "d", "e"])
    assert len(out) == 5
    assert [len(c["input"]) for c in captured] == [2, 2, 1]


def test_wrong_dimension_is_fatal():
    # Guards the B-1 failure mode (server lost --pooling last).
    emb = HttpEmbedder("http://e:8080", client=_server(768, captured=[]))
    with pytest.raises(RuntimeError, match="pooling last"):
        emb.embed(["x"])
