from __future__ import annotations

import hashlib
import sys
from pathlib import Path

from fastapi.testclient import TestClient


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "eval" / "embedder-stub"))

import app as embedder_stub_app  # noqa: E402


FIXTURE_PATH = ROOT / "tests" / "fixtures" / "embedder_stub_vectors.json"
KNOWN_INPUT = "def synthetic_fixture():\n    return 42\n"


def client() -> TestClient:
    settings = embedder_stub_app.Settings(
        mode="replay",
        fixture_path=FIXTURE_PATH,
    )
    return TestClient(embedder_stub_app.create_app(settings))


def test_stub_returns_recorded_vector_for_known_hash():
    response = client().post(
        "/v1/embeddings",
        json={"model": "nomic-embed-code", "input": [KNOWN_INPUT]},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["model"] == "nomic-embed-code"
    assert len(body["data"]) == 1
    assert len(body["data"][0]["embedding"]) == 3584
    assert body["data"][0]["embedding"][0] == 0.125


def test_stub_returns_503_for_missing_hash():
    missing_input = "def unknown_fixture():\n    return 0\n"
    digest = hashlib.sha256(missing_input.encode("utf-8")).hexdigest()

    response = client().post(
        "/v1/embeddings",
        json={"model": "nomic-embed-code", "input": [missing_input]},
    )

    assert response.status_code == 503
    assert digest in response.json()["detail"]
