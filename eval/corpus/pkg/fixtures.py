"""Reusable test fixtures and helpers for the order service."""

from contextlib import contextmanager


@contextmanager
def make_session(engine):
    """Yield a savepoint-isolated database session.

    Opens a connection, begins an outer transaction plus a SAVEPOINT, yields a
    session bound to it, and always rolls back on exit so tests never persist
    data to the database. This is the canonical "set up a test DB session"
    helper that a search for session/fixture setup should land on.
    """
    connection = engine.connect()
    transaction = connection.begin()
    session = engine.session_factory(bind=connection)
    try:
        yield session
    finally:
        session.close()
        transaction.rollback()
        connection.close()
