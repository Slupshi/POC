var builder = WebApplication.CreateBuilder(args);

var app = builder.Build();

// POST /payments/process — Traite le paiement
app.MapPost("/payments/process", (ProcessPaymentRequest request) =>
{
    // Simule un échec 1 fois sur 3 (aléatoire)
    if (Random.Shared.Next(3) == 0)
    {
        Console.WriteLine($"[Payment] Paiement refusé pour {request.OrderId}");
        return Results.UnprocessableEntity(new { reason = "Carte refusée (simulation)" });
    }

    Console.WriteLine($"[Payment] Paiement accepté pour {request.OrderId}");
    return Results.Ok(new { request.OrderId, status = "COMPLETED" });
});

app.Run();

// === Models ===
record ProcessPaymentRequest(Guid OrderId);
