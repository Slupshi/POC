using System.Net.Http.Json;
using SagaOrchestrator.Models;
using Temporalio.Activities;

namespace SagaOrchestrator.Activities;

public class OrderActivities(IHttpClientFactory httpClientFactory)
{
    [Activity]
    public async Task<Guid> CreateOrderAsync(string productId, int quantity)
    {
        using var client = httpClientFactory.CreateClient("OrderService");
        var response = await client.PostAsJsonAsync("/orders", new { productId, quantity });
        response.EnsureSuccessStatusCode();
        var order = await response.Content.ReadFromJsonAsync<CreateOrderResponse>();
        return order!.Id;
    }

    [Activity]
    public async Task ConfirmOrderAsync(Guid orderId)
    {
        using var client = httpClientFactory.CreateClient("OrderService");
        var response = await client.PutAsync($"/orders/{orderId}/confirm", null);
        response.EnsureSuccessStatusCode();
    }

    [Activity]
    public async Task CancelOrderAsync(Guid orderId)
    {
        using var client = httpClientFactory.CreateClient("OrderService");
        var response = await client.PutAsync($"/orders/{orderId}/cancel", null);
        response.EnsureSuccessStatusCode();
    }
}
