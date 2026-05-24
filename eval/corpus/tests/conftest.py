"""Pytest fixtures for the order tests: a savepoint-isolated db_session.

This conftest *defines* the db_session fixture. It is the file a search for
"session fixture setup / db_session" should surface first — the real-world case
where vault under-ranked the defining conftest below an empty __init__.py.
"""

import pytest

from pkg.fixtures import make_session


class FakeRepo:
    """Tiny in-memory order repository used by the service tests."""

    def __init__(self):
        self.saved = []
        self.gets = []

    def get(self, order_id):
        self.gets.append(order_id)
        return _FakeOrder(order_id)

    def save(self, order):
        self.saved.append(order)


class _FakeOrder:
    def __init__(self, order_id):
        self.id = order_id
        self.sent = False

    def mark_sent(self):
        self.sent = True


@pytest.fixture
def engine():
    """Engine handle used to build savepoint-isolated sessions."""
    return _build_test_engine()


@pytest.fixture
def db_session(engine):
    """Provide a savepoint-isolated database session per test.

    Wraps make_session so every test runs inside a SAVEPOINT that is rolled back
    on teardown; data never persists between tests.
    """
    with make_session(engine) as session:
        yield session


@pytest.fixture
def fake_repo():
    """An in-memory order repository for service tests."""
    return FakeRepo()
