"""Ephemeral indexer (Phase 1.2).

Run per job via ``docker run --rm`` — see ``indexer/index.py``. The
package is import-safe with no live services so the chunking and
orchestration logic is unit-testable offline (CI convention: in-memory
fakes, no Qdrant/embedder).
"""
