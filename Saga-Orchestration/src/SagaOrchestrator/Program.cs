using SagaOrchestrator.Activities;
using SagaOrchestrator.Models;
using SagaOrchestrator.Workflows;
using Temporalio.Client;
using Temporalio.Extensions.Hosting;

var builder = WebApplication.CreateBuilder(args);

// === HTTP Clients vers les 3 microservices (URLs configurables pour Docker) ===
var config = builder.Configuration;
builder.Services.AddHttpClient("OrderService", c => c.BaseAddress = new Uri(config["Services:OrderService"] ?? "http://localhost:5201"));
builder.Services.AddHttpClient("StockService", c => c.BaseAddress = new Uri(config["Services:StockService"] ?? "http://localhost:5202"));
builder.Services.AddHttpClient("PaymentService", c => c.BaseAddress = new Uri(config["Services:PaymentService"] ?? "http://localhost:5203"));

// === Temporal Client ===
builder.Services.AddTemporalClient(opts =>
{
    opts.TargetHost = config["Temporal:Host"] ?? "localhost:7233";
    opts.Namespace = "default";
});

// === Temporal Worker (héberge le workflow + les activities) ===
builder.Services
    .AddHostedTemporalWorker("order-saga-queue")
    .AddScopedActivities<OrderActivities>()
    .AddScopedActivities<StockActivities>()
    .AddScopedActivities<PaymentActivities>()
    .AddWorkflow<OrderSagaWorkflow>();

var app = builder.Build();

// POST /saga/orders — Démarre une saga de création de commande
app.MapPost("/saga/orders", async (CreateOrderRequest request, ITemporalClient client) =>
{
    var workflowId = $"order-saga-{Guid.NewGuid()}";

    var handle = await client.StartWorkflowAsync(
        (OrderSagaWorkflow wf) => wf.RunAsync(new OrderSagaInput(request.ProductId, request.Quantity)),
        new(id: workflowId, taskQueue: "order-saga-queue"));

    // Attend la fin du workflow et retourne le résultat
    var result = await handle.GetResultAsync();
    return Results.Ok(result);
});

// GET /saga/{workflowId} — Consulte le statut d'un workflow
app.MapGet("/saga/{workflowId}", async (string workflowId, ITemporalClient client) =>
{
    var handle = client.GetWorkflowHandle(workflowId);
    var desc = await handle.DescribeAsync();
    return Results.Ok(new { desc.Status, Id = desc.Id });
});

app.Run();

// === Models ===
record CreateOrderRequest(string ProductId, int Quantity);
