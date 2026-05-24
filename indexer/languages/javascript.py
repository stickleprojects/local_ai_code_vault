"""JavaScript language spec for the indexer chunker."""

from __future__ import annotations

import tree_sitter_javascript

from . import LanguageSpec

SPEC = LanguageSpec(
    name="javascript",
    extensions=(".js", ".jsx", ".mjs", ".cjs"),
    grammar_fn=tree_sitter_javascript.language,
    func_types=frozenset(
        {
            "function_declaration",
            "generator_function_declaration",
            "method_definition",
        }
    ),
    container_types=frozenset({"class_declaration"}),
)
