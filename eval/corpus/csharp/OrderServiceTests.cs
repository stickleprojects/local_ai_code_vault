using Xunit;

namespace Orders.Tests;

/// <summary>
/// Tests for OrderService.Publish.
///
/// These are *call sites*: OrderService is constructed and Publish is invoked
/// repeatedly here. They should NOT out-rank the definition in OrderService.cs
/// for definition-seeking queries. Mirrors tests/test_service.py.
/// </summary>
public class OrderServiceTests
{
    [Fact]
    public void Publish_MarksOrderSent()
    {
        var service = new OrderService(new FakeRepo());
        var result = service.Publish(1);
        Assert.True(result.Sent);
    }

    [Fact]
    public void Publish_SavesOrder()
    {
        var repo = new FakeRepo();
        var service = new OrderService(repo);
        service.Publish(2);
        Assert.Equal(2, repo.Saved[^1].Id);
    }

    [Fact]
    public void Publish_ReadsThroughRepository()
    {
        var repo = new FakeRepo();
        var service = new OrderService(repo);
        service.Publish(3);
        Assert.Contains(3, repo.Gets);
    }
}
