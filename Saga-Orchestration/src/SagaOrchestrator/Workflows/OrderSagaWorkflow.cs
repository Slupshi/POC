using SagaOrchestrator.Activities;
using SagaOrchestrator.Models;
using Temporalio.Workflows;

namespace SagaOrchestrator.Workflows;

[Workflow]
public class OrderSagaWorkflow
{
    // Pas de retry automatique : les échecs métier déclenchent les compensations
    private static readonly ActivityOptions DefaultOptions = new()
    {
        StartToCloseTimeout = TimeSpan.FromSeconds(30),
        RetryPolicy = new() { MaximumAttempts = 1 }
    };

    [WorkflowRun]
    public async Task<OrderSagaResult> RunAsync(OrderSagaInput input)
    {
        // ── T1 : Créer la commande (PENDING) ──
        var orderId = await Workflow.ExecuteActivityAsync(
            (OrderActivities a) => a.CreateOrderAsync(input.ProductId, input.Quantity),
            DefaultOptions);

        // ── T2 : Réserver le stock ──
        try
        {
            await Workflow.ExecuteActivityAsync(
                (StockActivities a) => a.ReserveStockAsync(orderId, input.ProductId, input.Quantity),
                DefaultOptions);
        }
        catch (Exception ex)
        {
            // C1 : Annuler la commande
            await Workflow.ExecuteActivityAsync(
                (OrderActivities a) => a.CancelOrderAsync(orderId),
                DefaultOptions);

            return new OrderSagaResult(orderId, "CANCELLED", $"Réservation stock échouée : {ex.Message}");
        }

        // ── T3 : Traiter le paiement ──
        try
        {
            await Workflow.ExecuteActivityAsync(
                (PaymentActivities a) => a.ProcessPaymentAsync(orderId),
                DefaultOptions);
        }
        catch (Exception ex)
        {
            // C2 : Libérer le stock
            await Workflow.ExecuteActivityAsync(
                (StockActivities a) => a.ReleaseStockAsync(orderId),
                DefaultOptions);

            // C1 : Annuler la commande
            await Workflow.ExecuteActivityAsync(
                (OrderActivities a) => a.CancelOrderAsync(orderId),
                DefaultOptions);

            return new OrderSagaResult(orderId, "CANCELLED", $"Paiement échoué : {ex.Message}");
        }

        // ── Confirmer la commande ──
        await Workflow.ExecuteActivityAsync(
            (OrderActivities a) => a.ConfirmOrderAsync(orderId),
            DefaultOptions);

        return new OrderSagaResult(orderId, "CONFIRMED", null);
    }
}
