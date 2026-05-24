from __future__ import annotations

import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel

from src.models import EMBED_DIM, EMBED_MODEL


class EmbeddingRequest(BaseModel):
    input: str | list[str]
    model: str | None = None


class VectorFixture:
    def __init__(self, path: Path):
        self.path = path
        self.model = EMBED_MODEL
        self.dim = EMBED_DIM
        self.corpus_sha = ""
        self.vectors: dict[str, list[float]] = {}
        if path.exists():
            self._load()

    def _load(self) -> None:
        payload = json.loads(self.path.read_text(encoding="utf-8"))
        self.model = str(payload.get("model") or EMBED_MODEL)
        self.dim = int(payload.get("dim") or EMBED_DIM)
        if self.dim != EMBED_DIM:
            raise RuntimeError(
                f"fixture dim {self.dim} does not match EMBED_DIM {EMBED_DIM}"
            )
        self.corpus_sha = str(payload.get("corpus_sha") or "")
        raw_vectors = payload.get("vectors") or {}
        vectors: dict[str, list[float]] = {}
        for key, value in raw_vectors.items():
            vec = [float(x) for x in value]
            if len(vec) != self.dim:
                raise RuntimeError(
                    f"fixture vector {key} has dim {len(vec)}, expected {self.dim}"
                )
            vectors[str(key)] = vec
        self.vectors = vectors

    def lookup(self, text: str) -> tuple[str, list[float] | None]:
        digest = sha256_text(text)
        return digest, self.vectors.get(digest)

    def upsert_many(self, inputs: list[str], vectors: list[list[float]], *, model: str | None, corpus_sha: str) -> None:
        if len(inputs) != len(vectors):
            raise RuntimeError(
                f"upstream returned {len(vectors)} vectors for {len(inputs)} inputs"
            )
        for text, vector in zip(inputs, vectors, strict=True):
            if len(vector) != EMBED_DIM:
                raise RuntimeError(
                    f"upstream returned dim {len(vector)}, expected {EMBED_DIM}"
                )
            digest = sha256_text(text)
            existing = self.vectors.get(digest)
            if existing is not None and existing != vector:
                raise RuntimeError(f"recorded vector changed for sha256={digest}")
            self.vectors[digest] = [float(x) for x in vector]
        self.model = str(model or self.model or EMBED_MODEL)
        self.dim = EMBED_DIM
        self.corpus_sha = corpus_sha
        self.write()

    def write(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "model": self.model or EMBED_MODEL,
            "dim": self.dim,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "corpus_sha": self.corpus_sha,
            "vectors": self.vectors,
        }
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        tmp.replace(self.path)


class Settings(BaseModel):
    mode: str = os.environ.get("EMBEDDER_STUB_MODE", "replay").strip().lower()
    fixture_path: Path = Path(os.environ.get("EMBEDDER_STUB_FIXTURE", "/fixtures/vectors.json"))
    upstream_url: str | None = os.environ.get("EMBEDDER_STUB_UPSTREAM_URL")
    corpus_sha: str = os.environ.get("EMBEDDER_STUB_CORPUS_SHA", "")


class RecorderProxy:
    def __init__(self, fixture: VectorFixture, upstream_url: str, corpus_sha: str):
        self.fixture = fixture
        self.upstream_url = upstream_url.rstrip("/")
        self.corpus_sha = corpus_sha
        self.client = httpx.Client(timeout=300.0)

    def handle(self, body: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        response = self.client.post(f"{self.upstream_url}/v1/embeddings", json=body)
        response.raise_for_status()
        payload = response.json()
        data = payload.get("data") or []
        vectors = [[float(x) for x in item["embedding"]] for item in data]
        inputs = normalize_inputs(body.get("input"))
        self.fixture.upsert_many(inputs, vectors, model=payload.get("model") or body.get("model"), corpus_sha=self.corpus_sha)
        return response.status_code, payload



def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()



def normalize_inputs(value: str | list[str] | Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return value
    raise HTTPException(status_code=400, detail="'input' must be a string or list of strings")



def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    fixture = VectorFixture(settings.fixture_path)
    proxy = None
    if settings.mode == "record":
        if not settings.upstream_url:
            raise RuntimeError("EMBEDDER_STUB_UPSTREAM_URL is required in record mode")
        proxy = RecorderProxy(fixture, settings.upstream_url, settings.corpus_sha)
    elif settings.mode != "replay":
        raise RuntimeError(f"unsupported EMBEDDER_STUB_MODE: {settings.mode}")

    app = FastAPI(title="embedder replay stub", version="0.1.0")

    @app.get("/healthz")
    def healthz() -> dict[str, Any]:
        return {
            "ok": True,
            "mode": settings.mode,
            "fixture": str(settings.fixture_path),
            "vector_count": len(fixture.vectors),
        }

    @app.post("/v1/embeddings")
    def embeddings(request: EmbeddingRequest) -> Response | dict[str, Any]:
        body = request.model_dump(exclude_none=True)
        if proxy is not None:
            status_code, payload = proxy.handle(body)
            return Response(
                content=json.dumps(payload),
                media_type="application/json",
                status_code=status_code,
            )

        inputs = normalize_inputs(request.input)
        rows = []
        for index, text in enumerate(inputs):
            digest, vector = fixture.lookup(text)
            if vector is None:
                raise HTTPException(
                    status_code=503,
                    detail=(
                        f"missing recorded embedding for sha256={digest}; "
                        "regenerate the fixture with eval/record-vectors.ps1"
                    ),
                )
            rows.append({"object": "embedding", "index": index, "embedding": vector})
        return {
            "object": "list",
            "data": rows,
            "model": fixture.model or request.model or EMBED_MODEL,
        }

    return app


app = create_app()
