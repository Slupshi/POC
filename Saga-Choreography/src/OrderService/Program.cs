using System.Collections.Concurrent;
using Contracts;
using MassTransit;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddMassTransit(x =>
{
    x.AddConsumer<PaymentCompletedConsumer>();
    x.AddConsumer<PaymentFailedConsumer>();
    x.AddConsumer<StockReservationFailedConsumer>();

    x.UsingRabbitMq((context, cfg) =>
    {
        var rabbitHost = builder.Configuration["RabbitMq:Host"] ?? "localhost";
        cfg.Host($"rabbitmq://{rabbitHost}");
        cfg.ConfigureEndpoints(context);
    });
});

var app = builder.Build();

// POST /orders — Crée une commande et publie OrderCreated
// ?simulateCrash=true : sauvegarde en mémoire mais n'envoie PAS l'événement → démontre le dual-write problem
app.MapPost("/orders", async (CreateOrderRequest request, IPublishEndpoint publish,
    [Microsoft.AspNetCore.Mvc.FromQuery] bool simulateCrash = false) =>
{
    var order = new Order(Guid.NewGuid(), request.ProductId, request.Quantity, "PENDING");
    OrderStore.Orders[order.Id] = order;
    Console.WriteLine($"[Order] Commande {order.Id} créée (PENDING)");

    if (simulateCrash)
    {
        // [PHASE 1a — DUAL-WRITE PROBLEM]
        // La commande est en BDD (mémoire) mais l'événement n'atteint JAMAIS RabbitMQ.
        // La saga ne démarre pas : OrderId reste PENDING indéfiniment.
        Console.WriteLine($"[Order][CHAOS] ⚠ Crash simulé avant publication → {order.Id} restera PENDING indéfiniment !");
        return Results.Created($"/orders/{order.Id}",
            new { order, chaos = "CRASH simulé : événement NON publié — saga bloquée (dual-write problem)" });
    }

    await publish.Publish(new OrderCreated(order.Id, order.ProductId, order.Quantity));
    return Results.Created($"/orders/{order.Id}", order);
});

// GET /orders — Liste toutes les commandes
app.MapGet("/orders", () => OrderStore.Orders.Values.ToList());

// GET /orders/{id}
app.MapGet("/orders/{id:guid}", (Guid id) =>
    OrderStore.Orders.TryGetValue(id, out var order) ? Results.Ok(order) : Results.NotFound());

app.Run();

// === State ===
static class OrderStore
{
    public static readonly ConcurrentDictionary<Guid, Order> Orders = new();
}

// === Models ===
record CreateOrderRequest(string ProductId, int Quantity);
record Order(Guid Id, string ProductId, int Quantity, string Status);

// === Consumers ===
class PaymentCompletedConsumer(ILogger<PaymentCompletedConsumer> logger) : IConsumer<PaymentCompleted>
{
    public Task Consume(ConsumeContext<PaymentCompleted> context)
    {
        var id = context.Message.OrderId;
        logger.LogInformation("[Order] Paiement OK pour {OrderId} → CONFIRMED", id);
        OrderStore.Orders[id] = OrderStore.Orders[id] with { Status = "CONFIRMED" };
        return Task.CompletedTask;
    }
}

class PaymentFailedConsumer(ILogger<PaymentFailedConsumer> logger, IPublishEndpoint publish) : IConsumer<PaymentFailed>
{
    public async Task Consume(ConsumeContext<PaymentFailed> context)
    {
        var id = context.Message.OrderId;
        logger.LogWarning("[Order] Paiement échoué pour {OrderId} → CANCELLED. Raison: {Reason}", id, context.Message.Reason);
        OrderStore.Orders[id] = OrderStore.Orders[id] with { Status = "CANCELLED" };
        await publish.Publish(new OrderCancelled(id));
    }
}

class StockReservationFailedConsumer(ILogger<StockReservationFailedConsumer> logger) : IConsumer<StockReservationFailed>
{
    public Task Consume(ConsumeContext<StockReservationFailed> context)
    {
        var id = context.Message.OrderId;
        logger.LogWarning("[Order] Stock refusé pour {OrderId} → CANCELLED. Raison: {Reason}", id, context.Message.Reason);
        OrderStore.Orders[id] = OrderStore.Orders[id] with { Status = "CANCELLED" };
        return Task.CompletedTask;
    }
}
