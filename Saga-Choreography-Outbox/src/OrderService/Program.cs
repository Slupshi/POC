using System.Text.Json;
using Contracts;
using MassTransit;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

// EF Core — SQLite
builder.Services.AddDbContext<AppDbContext>(opt =>
    opt.UseSqlite(builder.Configuration.GetConnectionString("Orders") ?? "Data Source=orders.db"));

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

// Background service : poller Outbox → RabbitMQ
builder.Services.AddHostedService<OutboxPollerService>();

var app = builder.Build();

// Auto-migration au démarrage
using (var scope = app.Services.CreateScope())
{
    scope.ServiceProvider.GetRequiredService<AppDbContext>().Database.EnsureCreated();
}

// POST /orders — Écrit Order + OutboxMessage dans la même transaction EF Core
// ?simulateCrash=true : simule un crash après le commit de la transaction
//   → démontre que le message Outbox sera quand même livré par le poller (contrairement à la Phase 1a)
app.MapPost("/orders", async (CreateOrderRequest request, AppDbContext db,
    [Microsoft.AspNetCore.Mvc.FromQuery] bool simulateCrash = false) =>
{
    var orderId = Guid.NewGuid();

    await using var tx = await db.Database.BeginTransactionAsync();

    db.Orders.Add(new OrderEntity { Id = orderId, ProductId = request.ProductId, Quantity = request.Quantity, Status = "PENDING" });

    // [OUTBOX] Sérialisation de l'événement dans la même transaction que la commande
    db.OutboxMessages.Add(new OutboxMessage
    {
        Id = Guid.NewGuid(),
        MessageType = nameof(OrderCreated),
        MessageBody = JsonSerializer.Serialize(new OrderCreated(orderId, request.ProductId, request.Quantity)),
        CreatedAt = DateTime.UtcNow
    });

    await db.SaveChangesAsync();
    await tx.CommitAsync(); // Order + OutboxMessage commits atomiquement

    Console.WriteLine($"[Order][Outbox] ✓ Commande {orderId} + message Outbox écrits en BDD (même transaction)");

    if (simulateCrash)
    {
        // [PHASE 1b — OUTBOX RÉSILIENT]
        // La transaction est déjà committée. Même si le processus crashait ici,
        // le OutboxPollerService livrera l'événement à RabbitMQ au prochain cycle.
        Console.WriteLine($"[Order][Outbox][CHAOS] ⚡ Crash simulé — mais le poller livrera {orderId} → saga continue !");
        return Results.Created($"/orders/{orderId}",
            new { orderId, status = "PENDING", chaos = "CRASH simulé — message Outbox déjà committé, livraison par le poller garantie" });
    }

    return Results.Created($"/orders/{orderId}", new { orderId, status = "PENDING" });
});

// GET /orders
app.MapGet("/orders", async (AppDbContext db) =>
    await db.Orders.ToListAsync());

// GET /orders/{id}
app.MapGet("/orders/{id:guid}", async (Guid id, AppDbContext db) =>
    await db.Orders.FindAsync(id) is { } o ? Results.Ok(o) : Results.NotFound());

app.Run();

// === EF Core ===
public class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    public DbSet<OrderEntity> Orders => Set<OrderEntity>();
    public DbSet<OutboxMessage> OutboxMessages => Set<OutboxMessage>();
}

public class OrderEntity
{
    public Guid Id { get; set; }
    public string ProductId { get; set; } = "";
    public int Quantity { get; set; }
    public string Status { get; set; } = "PENDING";
}

public class OutboxMessage
{
    public Guid Id { get; set; }
    public string MessageType { get; set; } = "";
    public string MessageBody { get; set; } = "";
    public DateTime CreatedAt { get; set; }
    public DateTime? ProcessedAt { get; set; }
}

// === Models ===
record CreateOrderRequest(string ProductId, int Quantity);

// === Outbox Poller ===
// Toutes les 2 secondes : lit les messages non traités de la table Outbox et les publie sur RabbitMQ.
// Garantit la livraison at-least-once même si le handler HTTP a crashé après le commit.
public class OutboxPollerService(IServiceScopeFactory scopeFactory, ILogger<OutboxPollerService> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
                var bus = scope.ServiceProvider.GetRequiredService<IBus>();

                var pending = await db.OutboxMessages
                    .Where(m => m.ProcessedAt == null)
                    .OrderBy(m => m.CreatedAt)
                    .ToListAsync(stoppingToken);

                foreach (var msg in pending)
                {
                    await PublishOutboxMessage(bus, msg, stoppingToken);
                    msg.ProcessedAt = DateTime.UtcNow;
                    logger.LogInformation("[Outbox] ✓ Message {Id} ({Type}) livré à RabbitMQ", msg.Id, msg.MessageType);
                }

                if (pending.Count > 0)
                    await db.SaveChangesAsync(stoppingToken);
            }
            catch (Exception ex) when (!stoppingToken.IsCancellationRequested)
            {
                logger.LogError(ex, "[Outbox] Erreur poller — retry dans 2s");
            }

            await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken);
        }
    }

    private static Task PublishOutboxMessage(IBus bus, OutboxMessage msg, CancellationToken ct) =>
        msg.MessageType switch
        {
            nameof(OrderCreated) => bus.Publish(
                JsonSerializer.Deserialize<OrderCreated>(msg.MessageBody)!, ct),
            nameof(OrderCancelled) => bus.Publish(
                JsonSerializer.Deserialize<OrderCancelled>(msg.MessageBody)!, ct),
            _ => Task.CompletedTask
        };
}

// === Consumers (status updates via événements entrants) ===
class PaymentCompletedConsumer(ILogger<PaymentCompletedConsumer> logger, AppDbContext db) : IConsumer<PaymentCompleted>
{
    public async Task Consume(ConsumeContext<PaymentCompleted> context)
    {
        var id = context.Message.OrderId;
        logger.LogInformation("[Order] Paiement OK pour {OrderId} → CONFIRMED", id);
        var order = await db.Orders.FindAsync(id);
        if (order is not null) { order.Status = "CONFIRMED"; await db.SaveChangesAsync(); }
    }
}

class PaymentFailedConsumer(ILogger<PaymentFailedConsumer> logger, AppDbContext db) : IConsumer<PaymentFailed>
{
    public async Task Consume(ConsumeContext<PaymentFailed> context)
    {
        var id = context.Message.OrderId;
        logger.LogWarning("[Order] Paiement échoué pour {OrderId} → CANCELLED. Raison: {Reason}", id, context.Message.Reason);
        var order = await db.Orders.FindAsync(id);
        if (order is not null) { order.Status = "CANCELLED"; await db.SaveChangesAsync(); }

        // Compensation écrite via Outbox aussi (même garantie)
        db.OutboxMessages.Add(new OutboxMessage
        {
            Id = Guid.NewGuid(),
            MessageType = nameof(OrderCancelled),
            MessageBody = JsonSerializer.Serialize(new OrderCancelled(id)),
            CreatedAt = DateTime.UtcNow
        });
        await db.SaveChangesAsync();
    }
}

class StockReservationFailedConsumer(ILogger<StockReservationFailedConsumer> logger, AppDbContext db) : IConsumer<StockReservationFailed>
{
    public async Task Consume(ConsumeContext<StockReservationFailed> context)
    {
        var id = context.Message.OrderId;
        logger.LogWarning("[Order] Stock refusé pour {OrderId} → CANCELLED. Raison: {Reason}", id, context.Message.Reason);
        var order = await db.Orders.FindAsync(id);
        if (order is not null) { order.Status = "CANCELLED"; await db.SaveChangesAsync(); }
    }
}
