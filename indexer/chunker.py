"""Tree-sitter chunking for C#, Python, JavaScript, TypeScript (AD-8).

Granularity is function/class: each top-level function-like declaration
becomes one chunk, each container (class/struct/interface/namespace)
becomes one chunk *and* is descended into so its methods are captured
too. A supported file with no such declarations (e.g. a script of
top-level statements) still yields a single whole-file chunk so its
content remains searchable.

Language support is extended by adding a module to ``indexer/languages/``
— nothing here changes.  The per-language node-type sets, grammar
callables, and extension mappings all live in that package.

Unsupported extensions return ``language_for() is None`` and are counted
as ``skipped`` by the orchestrator (AD-9), never errored.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from functools import lru_cache

from tree_sitter import Language, Node, Parser

from .languages import EXT_LANG, REGISTRY, LanguageSpec

# Files larger than this are skipped (not chunked): almost certainly
# generated/minified, and they blow up embedding cost for no signal.
MAX_FILE_BYTES = 1_000_000


@dataclass(frozen=True)
class Chunk:
    """One indexable unit. ``start_line``/``end_line`` are 1-based.

    ``start_byte``/``end_byte`` are the source offsets; they make the
    chunk's identity unique even when several declarations share a line
    (e.g. minified or single-line C#), and are stable across re-index.

    ``symbol`` is the declared identifier extracted from the tree-sitter
    node (e.g. ``"OrderService"`` for a class declaration chunk).
    Whole-file fallback chunks leave it ``None``.
    """

    path: str  # repo-relative, POSIX separators
    language: str
    start_line: int
    end_line: int
    start_byte: int
    end_byte: int
    text: str
    symbol: str | None = field(default=None)


def language_for(rel_path: str) -> str | None:
    """Internal language name for a path, or ``None`` if unsupported."""
    lower = rel_path.lower()
    dot = lower.rfind(".")
    if dot == -1:
        return None
    return EXT_LANG.get(lower[dot:])


@lru_cache(maxsize=None)
def _parser(language: str) -> Parser:
    return Parser(Language(REGISTRY[language].grammar_fn()))


def _emit(
    node: Node, source: bytes, path: str, language: str, spec: LanguageSpec
) -> Chunk:
    return Chunk(
        path=path,
        language=language,
        start_line=node.start_point[0] + 1,
        end_line=node.end_point[0] + 1,
        start_byte=node.start_byte,
        end_byte=node.end_byte,
        text=source[node.start_byte : node.end_byte].decode("utf-8", "replace"),
        symbol=spec.symbol_name(node),
    )


def chunk_source(rel_path: str, source: bytes, language: str) -> list[Chunk]:
    """Parse ``source`` and return its function/class chunks.

    Falls back to one whole-file chunk when the file parses but contains
    no function/class declarations, so scripts are still searchable.
    """
    spec = REGISTRY[language]
    funcs = spec.func_types
    containers = spec.container_types
    tree = _parser(language).parse(source)

    chunks: list[Chunk] = []

    def walk(node: Node) -> None:
        for child in node.children:
            if child.type in funcs:
                chunks.append(_emit(child, source, rel_path, language, spec))
                # Don't descend: nested closures rarely help retrieval.
            elif child.type in containers:
                chunks.append(_emit(child, source, rel_path, language, spec))
                walk(child)  # descend to capture methods
            else:
                walk(child)

    walk(tree.root_node)

    if not chunks:
        text = source.decode("utf-8", "replace")
        if text.strip():
            chunks.append(
                Chunk(
                    path=rel_path,
                    language=language,
                    start_line=1,
                    end_line=text.count("\n") + 1,
                    start_byte=0,
                    end_byte=len(source),
                    text=text,
                    symbol=None,
                )
            )
    return chunks
