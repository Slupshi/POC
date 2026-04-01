using System.Collections.Concurrent;

var builder = WebApplication.CreateBuilder(args);

var app = builder.Build();

// POST /orders — Crée une commande (PENDING)
app.MapPost("/orders", (CreateOrderRequest request) =>
{
    var order = new Order(Guid.NewGuid(), request.ProductId, request.Quantity, "PENDING");
    OrderStore.Orders[order.Id] = order;

    Console.WriteLine($"[Order] Commande {order.Id} créée (PENDING)");
    return Results.Created($"/orders/{order.Id}", order);
});

// PUT /orders/{id}/confirm — Confirme la commande
app.MapPut("/orders/{id:guid}/confirm", (Guid id) =>
{
    if (!OrderStore.Orders.TryGetValue(id, out var order))
        return Results.NotFound();

    OrderStore.Orders[id] = order with { Status = "CONFIRMED" };
    Console.WriteLine($"[Order] Commande {id} → CONFIRMED");
    return Results.Ok(OrderStore.Orders[id]);
});

// PUT /orders/{id}/cancel — Annule la commande (compensation)
app.MapPut("/orders/{id:guid}/cancel", (Guid id) =>
{
    if (!OrderStore.Orders.TryGetValue(id, out var order))
        return Results.NotFound();

    OrderStore.Orders[id] = order with { Status = "CANCELLED" };
    Console.WriteLine($"[Order] COMPENSATION — Commande {id} → CANCELLED");
    return Results.Ok(OrderStore.Orders[id]);
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
