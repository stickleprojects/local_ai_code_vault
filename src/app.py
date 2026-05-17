"""FastAPI service: status, repo registry, and AD-9 introspection.

Phase 1.1 scope. Semantic search (`/api/query/{repo_id}`) is declared
here but deliberately returns 501 until Phase 1.3 (it needs the embedder
and indexed data, which Phase 1.2/1.3 deliver).

The app never refuses to start when Qdrant is unreachable — `/api/status`
reports `qdrant_connected: false` instead, and `/api/repos` returns `[]`.
"""

from __future__ import annotations

import os

from fastapi import Depends, FastAPI, HTTPException, Query

from .inspection import Inspector
from .models import (
    ErrorResponse,
    FilesResponse,
    QueryResponse,
    RepoDetail,
    RepoStats,
    RepoSummary,
    StatusResponse,
)
from .query_handler import HttpQueryEmbedder, QueryHandler
from .registry import QdrantRegistry

_NOT_FOUND = {404: {"model": ErrorResponse}}


def create_app(registry=None, query_embedder=None) -> FastAPI:
    app = FastAPI(title="local_ai_code_vault API", version="0.1.0")
    app.state.registry = registry if registry is not None else QdrantRegistry()
    app.state.query_embedder = (
        query_embedder
        if query_embedder is not None
        else HttpQueryEmbedder(
            os.environ.get("EMBEDDER_URL", "http://embedder:8080")
        )
    )

    def get_registry():
        return app.state.registry

    def get_query_handler() -> QueryHandler:
        return QueryHandler(app.state.registry, app.state.query_embedder)

    @app.get("/api/status", response_model=StatusResponse)
    def status(reg=Depends(get_registry)) -> StatusResponse:
        return StatusResponse(qdrant_connected=reg.is_connected())

    @app.get("/api/repos", response_model=list[RepoSummary])
    def list_repos(reg=Depends(get_registry)):
        return reg.list_repos()

    @app.get("/api/repos/{repo_id}", response_model=RepoDetail, responses=_NOT_FOUND)
    def get_repo(repo_id: str, reg=Depends(get_registry)):
        repo = reg.get_repo(repo_id)
        if repo is None:
            raise HTTPException(404, f"repo '{repo_id}' is not registered")
        return repo

    @app.get(
        "/api/repos/{repo_id}/stats", response_model=RepoStats, responses=_NOT_FOUND
    )
    def repo_stats(repo_id: str, reg=Depends(get_registry)):
        result = Inspector(reg).stats(repo_id)
        if result is None:
            raise HTTPException(404, f"repo '{repo_id}' is not registered")
        return result

    @app.get(
        "/api/repos/{repo_id}/files",
        response_model=FilesResponse,
        responses=_NOT_FOUND,
    )
    def repo_files(
        repo_id: str,
        offset: int = Query(0, ge=0),
        limit: int = Query(100, ge=1, le=1000),
        reg=Depends(get_registry),
    ):
        result = Inspector(reg).files(repo_id, offset, limit)
        if result is None:
            raise HTTPException(404, f"repo '{repo_id}' is not registered")
        return result

    @app.get(
        "/api/query/{repo_id}",
        response_model=QueryResponse,
        responses=_NOT_FOUND,
    )
    def query(
        repo_id: str,
        q: str = Query(..., min_length=1),
        limit: int = Query(10, ge=1, le=50),
        handler: QueryHandler = Depends(get_query_handler),
    ):
        result = handler.query(repo_id, q, limit)
        if result is None:
            raise HTTPException(404, f"repo '{repo_id}' is not registered")
        return result

    return app


app = create_app()
