"""TypeScript (and TSX) language specs for the indexer chunker."""

from __future__ import annotations

import tree_sitter_typescript

from . import LanguageSpec

_FUNC_TYPES = frozenset(
    {
        "function_declaration",
        "generator_function_declaration",
        "method_definition",
    }
)

_CONTAINER_TYPES = frozenset(
    {
        "class_declaration",
        "interface_declaration",
    }
)

SPEC = LanguageSpec(
    name="typescript",
    extensions=(".ts", ".mts", ".cts"),
    grammar_fn=tree_sitter_typescript.language_typescript,
    func_types=_FUNC_TYPES,
    container_types=_CONTAINER_TYPES,
)

TSX_SPEC = LanguageSpec(
    name="tsx",
    extensions=(".tsx",),
    grammar_fn=tree_sitter_typescript.language_tsx,
    func_types=_FUNC_TYPES,
    container_types=_CONTAINER_TYPES,
)
