using Contracts;
using MassTransit;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddMassTransit(x =>
{
    x.AddConsumer<StockReservedConsumer>();

    x.UsingRabbitMq((context, cfg) =>
    {
        var rabbitHost = builder.Configuration["RabbitMq:Host"] ?? "localhost";
        cfg.Host($"rabbitmq://{rabbitHost}");
        cfg.ConfigureEndpoints(context);
    });
});

var app = builder.Build();
app.Run();

// === Consumers ===
class StockReservedConsumer(ILogger<StockReservedConsumer> logger, IPublishEndpoint publish) : IConsumer<StockReserved>
{
    public async Task Consume(ConsumeContext<StockReserved> context)
    {
        var orderId = context.Message.OrderId;

        // Simule un échec 1 fois sur 3 (aléatoire)
        if (Random.Shared.Next(3) == 0)
        {
            logger.LogWarning("[Payment] Paiement refusé pour {OrderId}", orderId);
            await publish.Publish(new PaymentFailed(orderId, "Carte refusée (simulation)"));
            return;
        }

        logger.LogInformation("[Payment] Paiement accepté pour {OrderId}", orderId);
        await publish.Publish(new PaymentCompleted(orderId));
    }
}
