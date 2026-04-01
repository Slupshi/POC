using System.Net.Http.Json;
using Temporalio.Activities;

namespace SagaOrchestrator.Activities;

public class StockActivities(IHttpClientFactory httpClientFactory)
{
    [Activity]
    public async Task ReserveStockAsync(Guid orderId, string productId, int quantity)
    {
        using var client = httpClientFactory.CreateClient("StockService");
        var response = await client.PostAsJsonAsync("/stock/reserve", new { orderId, productId, quantity });

        if (!response.IsSuccessStatusCode)
        {
            var error = await response.Content.ReadAsStringAsync();
            throw new ApplicationException($"Stock reservation failed: {error}");
        }
    }

    [Activity]
    public async Task ReleaseStockAsync(Guid orderId)
    {
        using var client = httpClientFactory.CreateClient("StockService");
        var response = await client.PostAsJsonAsync("/stock/release", new { orderId });
        response.EnsureSuccessStatusCode();
    }
}
