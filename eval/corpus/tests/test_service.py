"""Tests for OrderService.publish.

These are *call sites*: OrderService and the db_session fixture are used
repeatedly here. They should NOT out-rank the definitions in pkg/service.py and
tests/conftest.py for definition-seeking queries.
"""

from pkg.service import OrderService


def test_publish_marks_order_sent(db_session, fake_repo):
    service = OrderService(fake_repo)
    result = service.publish(order_id=1)
    assert result.sent is True


def test_publish_saves_order(db_session, fake_repo):
    service = OrderService(fake_repo)
    service.publish(order_id=2)
    assert fake_repo.saved[-1].id == 2


def test_publish_reads_through_repository(db_session, fake_repo):
    service = OrderService(fake_repo)
    service.publish(order_id=3)
    assert 3 in fake_repo.gets
