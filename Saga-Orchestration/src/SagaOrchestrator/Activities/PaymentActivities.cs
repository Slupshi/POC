using System.Net.Http.Json;
using Temporalio.Activities;

namespace SagaOrchestrator.Activities;

public class PaymentActivities(IHttpClientFactory httpClientFactory)
{
    [Activity]
    public async Task ProcessPaymentAsync(Guid orderId)
    {
        using var client = httpClientFactory.CreateClient("PaymentService");
        var response = await client.PostAsJsonAsync("/payments/process", new { orderId });

        if (!response.IsSuccessStatusCode)
        {
            var error = await response.Content.ReadAsStringAsync();
            throw new ApplicationException($"Payment failed: {error}");
        }
    }
}
