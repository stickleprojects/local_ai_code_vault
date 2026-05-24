"""Per-language specs for the indexer chunker.

Each supported language is described by a :class:`LanguageSpec` — a
declarative bundle of grammar, node-type sets, extension mappings, and
the helper that extracts the declared symbol name from a tree-sitter
node.  Adding a language means adding one module here; nothing in
``chunker.py`` needs to change.

The registry is keyed by the internal language name (the same strings
used in ``payload["language"]`` and throughout ``src/``).  Extension →
language mapping is also derived here so there is exactly one place
to update when support for a new file type is added.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from tree_sitter import Node


@dataclass(frozen=True)
class LanguageSpec:
    """Declarative descriptor for one tree-sitter language.

    Attributes
    ----------
    name:
        Internal language name (e.g. ``"python"``).  Used as the
        ``payload["language"]`` value in Qdrant and as the key in
        :data:`REGISTRY`.
    extensions:
        Lowercase file extensions (including the leading dot) that map
        to this language, e.g. ``(".py", ".pyi")``.
    grammar_fn:
        Zero-argument callable that returns the tree-sitter
        ``Language`` capsule, e.g. ``tree_sitter_python.language``.
    func_types:
        Node types emitted as a chunk but *not* descended into (methods,
        free functions, constructors…).
    container_types:
        Node types emitted as a chunk *and* descended into so that the
        declarations inside them are captured separately (classes,
        interfaces, namespaces…).
    """

    name: str
    extensions: tuple[str, ...]
    grammar_fn: Callable
    func_types: frozenset[str]
    container_types: frozenset[str]

    def symbol_name(self, node: Node) -> str | None:
        """Return the declared identifier text for a func/container node.

        Uses the tree-sitter ``name`` named-field, which is present on
        every node type listed in :attr:`func_types` /
        :attr:`container_types` for all four supported languages.
        Returns ``None`` when the field is absent (e.g. anonymous
        function expressions that somehow reach this path).
        """
        child = node.child_by_field_name("name")
        if child is None or child.text is None:
            return None
        return child.text.decode("utf-8", "replace")


# ---------------------------------------------------------------------------
# Per-language modules register their specs here.
# ---------------------------------------------------------------------------
from .python import SPEC as _PY_SPEC  # noqa: E402
from .csharp import SPEC as _CS_SPEC  # noqa: E402
from .javascript import SPEC as _JS_SPEC  # noqa: E402
from .typescript import SPEC as _TS_SPEC, TSX_SPEC as _TSX_SPEC  # noqa: E402

#: Internal-name → LanguageSpec registry.
REGISTRY: dict[str, LanguageSpec] = {
    spec.name: spec
    for spec in (_PY_SPEC, _CS_SPEC, _JS_SPEC, _TS_SPEC, _TSX_SPEC)
}

#: Extension → internal language name (mirrors the old ``_EXT_LANG`` dict).
EXT_LANG: dict[str, str] = {
    ext: spec.name
    for spec in REGISTRY.values()
    for ext in spec.extensions
}
