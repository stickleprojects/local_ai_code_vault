"""Tree-sitter chunking for C#, Python, JavaScript, TypeScript (AD-8).

Granularity is function/class: each top-level function-like declaration
becomes one chunk, each container (class/struct/interface/namespace)
becomes one chunk *and* is descended into so its methods are captured
too. A supported file with no such declarations (e.g. a script of
top-level statements) still yields a single whole-file chunk so its
content remains searchable.

Language support is extended by adding an extension mapping, a grammar,
and its node-type rules below — nothing else in the indexer changes.

Unsupported extensions return ``language_for() is None`` and are counted
as ``skipped`` by the orchestrator (AD-9), never errored.
"""

from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache

from tree_sitter import Language, Node, Parser

import tree_sitter_c_sharp
import tree_sitter_javascript
import tree_sitter_python
import tree_sitter_typescript

# Files larger than this are skipped (not chunked): almost certainly
# generated/minified, and they blow up embedding cost for no signal.
MAX_FILE_BYTES = 1_000_000

# extension -> internal language name. ``language`` in the registry /
# per-language stats uses these names.
_EXT_LANG: dict[str, str] = {
    ".py": "python",
    ".pyi": "python",
    ".cs": "csharp",
    ".js": "javascript",
    ".jsx": "javascript",
    ".mjs": "javascript",
    ".cjs": "javascript",
    ".ts": "typescript",
    ".mts": "typescript",
    ".cts": "typescript",
    ".tsx": "tsx",
}

# Function-like nodes: emitted as a chunk, not descended into.
_FUNC_TYPES: dict[str, set[str]] = {
    "python": {"function_definition"},
    "javascript": {
        "function_declaration",
        "generator_function_declaration",
        "method_definition",
    },
    "typescript": {
        "function_declaration",
        "generator_function_declaration",
        "method_definition",
    },
    "tsx": {
        "function_declaration",
        "generator_function_declaration",
        "method_definition",
    },
    "csharp": {
        "method_declaration",
        "constructor_declaration",
        "destructor_declaration",
        "local_function_statement",
    },
}

# Container nodes: emitted as a chunk *and* descended into so the
# methods/functions inside them are captured as their own chunks.
_CONTAINER_TYPES: dict[str, set[str]] = {
    "python": {"class_definition"},
    "javascript": {"class_declaration"},
    "typescript": {"class_declaration", "interface_declaration"},
    "tsx": {"class_declaration", "interface_declaration"},
    "csharp": {
        "class_declaration",
        "struct_declaration",
        "interface_declaration",
        "record_declaration",
        "namespace_declaration",
        "file_scoped_namespace_declaration",
    },
}


@dataclass(frozen=True)
class Chunk:
    """One indexable unit. ``start_line``/``end_line`` are 1-based.

    ``start_byte``/``end_byte`` are the source offsets; they make the
    chunk's identity unique even when several declarations share a line
    (e.g. minified or single-line C#), and are stable across re-index.
    """

    path: str  # repo-relative, POSIX separators
    language: str
    start_line: int
    end_line: int
    start_byte: int
    end_byte: int
    text: str


def language_for(rel_path: str) -> str | None:
    """Internal language name for a path, or ``None`` if unsupported."""
    lower = rel_path.lower()
    dot = lower.rfind(".")
    if dot == -1:
        return None
    return _EXT_LANG.get(lower[dot:])


@lru_cache(maxsize=None)
def _parser(language: str) -> Parser:
    grammar = {
        "python": tree_sitter_python.language,
        "javascript": tree_sitter_javascript.language,
        "typescript": tree_sitter_typescript.language_typescript,
        "tsx": tree_sitter_typescript.language_tsx,
        "csharp": tree_sitter_c_sharp.language,
    }[language]
    return Parser(Language(grammar()))


def _emit(node: Node, source: bytes, path: str, language: str) -> Chunk:
    return Chunk(
        path=path,
        language=language,
        start_line=node.start_point[0] + 1,
        end_line=node.end_point[0] + 1,
        start_byte=node.start_byte,
        end_byte=node.end_byte,
        text=source[node.start_byte : node.end_byte].decode("utf-8", "replace"),
    )


def chunk_source(rel_path: str, source: bytes, language: str) -> list[Chunk]:
    """Parse ``source`` and return its function/class chunks.

    Falls back to one whole-file chunk when the file parses but contains
    no function/class declarations, so scripts are still searchable.
    """
    funcs = _FUNC_TYPES[language]
    containers = _CONTAINER_TYPES[language]
    tree = _parser(language).parse(source)

    chunks: list[Chunk] = []

    def walk(node: Node) -> None:
        for child in node.children:
            if child.type in funcs:
                chunks.append(_emit(child, source, rel_path, language))
                # Don't descend: nested closures rarely help retrieval.
            elif child.type in containers:
                chunks.append(_emit(child, source, rel_path, language))
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
                )
            )
    return chunks
