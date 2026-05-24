"""Python language spec for the indexer chunker."""

from __future__ import annotations

import tree_sitter_python

from . import LanguageSpec

SPEC = LanguageSpec(
    name="python",
    extensions=(".py", ".pyi"),
    grammar_fn=tree_sitter_python.language,
    func_types=frozenset({"function_definition"}),
    container_types=frozenset({"class_definition"}),
)
