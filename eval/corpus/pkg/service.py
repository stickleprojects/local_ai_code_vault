"""Order publication service — defines OrderService."""


class OrderService:
    """Publishes orders to the downstream queue.

    This is the *definition* site for OrderService. A query about publishing
    orders, or an exact-symbol search for OrderService, should rank this above
    the test call sites in tests/test_service.py.
    """

    def __init__(self, repository):
        self._repository = repository

    def publish(self, order_id):
        """Publish a single order by id and mark it as sent."""
        order = self._repository.get(order_id)
        order.mark_sent()
        self._repository.save(order)
        return order
