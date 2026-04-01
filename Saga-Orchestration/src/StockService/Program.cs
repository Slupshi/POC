var builder = WebApplication.CreateBuilder(args);

var app = builder.Build();

// POST /stock/reserve — Réserve le stock
app.MapPost("/stock/reserve", (ReserveStockRequest request) =>
{
    // Simule un échec si quantité > 100
    if (request.Quantity > 100)
    {
        Console.WriteLine($"[Stock] Stock insuffisant pour {request.OrderId} (qté: {request.Quantity})");
        return Results.UnprocessableEntity(new { reason = $"Stock insuffisant pour {request.Quantity} unités" });
    }

    Console.WriteLine($"[Stock] Stock réservé pour {request.OrderId} (produit: {request.ProductId}, qté: {request.Quantity})");
    return Results.Ok(new { request.OrderId, status = "RESERVED" });
});

// POST /stock/release — Libère le stock (compensation)
app.MapPost("/stock/release", (ReleaseStockRequest request) =>
{
    Console.WriteLine($"[Stock] COMPENSATION — Libération du stock pour {request.OrderId}");
    return Results.Ok(new { request.OrderId, status = "RELEASED" });
});

app.Run();

// === Models ===
record ReserveStockRequest(Guid OrderId, string ProductId, int Quantity);
record ReleaseStockRequest(Guid OrderId);
