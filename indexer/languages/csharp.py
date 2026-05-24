"""C# language spec for the indexer chunker."""

from __future__ import annotations

import tree_sitter_c_sharp

from . import LanguageSpec

SPEC = LanguageSpec(
    name="csharp",
    extensions=(".cs",),
    grammar_fn=tree_sitter_c_sharp.language,
    func_types=frozenset(
        {
            "method_declaration",
            "constructor_declaration",
            "destructor_declaration",
            "local_function_statement",
        }
    ),
    container_types=frozenset(
        {
            "class_declaration",
            "struct_declaration",
            "interface_declaration",
            "record_declaration",
            "namespace_declaration",
            "file_scoped_namespace_declaration",
        }
    ),
)
