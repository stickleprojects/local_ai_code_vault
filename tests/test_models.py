from src.models import (
    CODE_PREFIX,
    EMBED_DIM,
    EMBED_MODEL,
    QUERY_PREFIX,
    format_code,
    format_query,
)


def test_embedding_contract_constants():
    # Verified via BLOCKER B-1 resolution — must never silently change.
    assert EMBED_DIM == 3584
    assert EMBED_MODEL == "nomic-embed-code"


def test_ad10_prefix_asymmetry():
    assert QUERY_PREFIX == "Represent this query for searching relevant code: "
    assert CODE_PREFIX == ""
    assert format_query("find auth").startswith(QUERY_PREFIX)
    assert format_query("find auth").endswith("find auth")
    # Code is embedded with no prefix.
    assert format_code("def f(): pass") == "def f(): pass"
