namespace Orders;

/// <summary>
/// Publishes orders to the downstream queue.
///
/// This is the *definition* site for OrderService. A query about publishing
/// orders, or an exact-symbol search for OrderService, should rank this above
/// the test call sites in OrderServiceTests.cs. It mirrors pkg/service.py so the
/// language-general symbol boost (PR 4) can be verified for C#, not just Python.
/// </summary>
public class OrderService
{
    private readonly IOrderRepository _repository;

    public OrderService(IOrderRepository repository)
    {
        _repository = repository;
    }

    /// <summary>Publish a single order by id and mark it as sent.</summary>
    public Order Publish(int orderId)
    {
        var order = _repository.Get(orderId);
        order.MarkSent();
        _repository.Save(order);
        return order;
    }
}
