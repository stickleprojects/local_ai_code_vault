# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Versioning & release convention

- **Version scheme:** SemVer `MAJOR.MINOR.PATCH`. The single source of
  truth for the current version is `version` in `pyproject.toml`.
- **MAJOR** — a broken sacred contract (`repo_id` derivation, the
  embedding model/dim, or the prompt-prefix asymmetry; see CLAUDE.md)
  or any change requiring a full re-index.
- **MINOR** — new capability that is backward compatible (a new script,
  endpoint, language, or skill command).
- **PATCH** — fixes and docs/CI/dependency changes with no contract
  impact.
- **Releasing:** move `[Unreleased]` items under a new
  `## [x.y.z] - YYYY-MM-DD` heading, bump `pyproject.toml`, then push an
  annotated git tag `vx.y.z` (e.g. `git tag -a v0.1.0 -m v0.1.0 &&
  git push origin v0.1.0`). The tag push triggers
  `.github/workflows/release.yml`, which publishes a GitHub Release from
  the matching CHANGELOG section. No container images are published
  (Phase 4.1 deferred — see `plan.md`).

## [Unreleased]

First tagged release will be **v0.1.0** (Phases 1–3). Pre-tag history,
by phase / PR:

### Added

- **Phase 1.1 — API & repo registry** (#2): FastAPI service; implicit
  repo registry in a reserved Qdrant collection; `src/models.py` as the
  single source of truth for the embedding contract.
- **Phase 1.2 — Indexer** (#3): standalone per-job image; tree-sitter
  chunking (C#/Python/JS/TS), embedder, Qdrant writer, CLI; round-trip
  test locking the registry payload contract.
- **Phase 1.3 — Query** (#4): semantic search path with the AD-10
  prompt-prefix asymmetry (queries prefixed, code raw).
- **Phase 1.4 — Compose stack** (#5): `qdrant` + `embedder`
  (`llama.cpp` CUDA) + `api`, plus SHA256-pinned one-shot `model-fetch`
  for the `nomic-embed-code` GGUF.
- **Phase 2 — Skill & host scripts** (#6): AD-4 "thin skill, fat
  scripts" — standalone `scripts/*.ps1` with a uniform JSON-stdout /
  exit-code contract; `SKILL.md` delegates only.
- **Phase 3 — Test suite** (#8): Pester host-script suite driving real
  scripts (temp git + HttpListener API stub + PATH-shim docker); a
  `pester` CI job alongside `pytest`; manual E2E smoke test.
- AD-9 read-only inspection endpoint/script (`vault-inspect`).
- Git-hook installer for post-commit re-index freshness.
- This `CHANGELOG.md` and a tag-triggered GitHub Release workflow
  (Phase 4.2, lightweight).

### Fixed

- Cross-repo skill install: the skill is usable from any repo with no
  per-repo copying (#9).

### Changed

- Docs/CI refresh; CI prints test names (#7).
- Bounded `qdrant-client` to the pinned server minor (`>=1.12,<1.13`)
  to stop `pip` resolving a mismatched major.

### Deferred

- **Phase 4.1 / 4.3** — GHCR image publishing and its `GHCR_TOKEN`
  secret. Single-user local tool; images build locally and cache.
  Rationale recorded in `plan.md`.
