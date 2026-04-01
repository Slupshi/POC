using Contracts;
using MassTransit;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddMassTransit(x =>
{
    x.AddConsumer<OrderCreatedConsumer>();
    x.AddConsumer<OrderCancelledConsumer>();

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
class OrderCreatedConsumer(ILogger<OrderCreatedConsumer> logger, IPublishEndpoint publish) : IConsumer<OrderCreated>
{
    public async Task Consume(ConsumeContext<OrderCreated> context)
    {
        var msg = context.Message;

        // Simule un échec si quantité > 100
        if (msg.Quantity > 100)
        {
            logger.LogWarning("[Stock] Stock insuffisant pour {OrderId} (qté: {Qty})", msg.OrderId, msg.Quantity);
            await publish.Publish(new StockReservationFailed(msg.OrderId, $"Stock insuffisant pour {msg.Quantity} unités"));
            return;
        }

        logger.LogInformation("[Stock] Stock réservé pour {OrderId} (produit: {Product}, qté: {Qty})", msg.OrderId, msg.ProductId, msg.Quantity);
        await publish.Publish(new StockReserved(msg.OrderId));
    }
}

class OrderCancelledConsumer(ILogger<OrderCancelledConsumer> logger) : IConsumer<OrderCancelled>
{
    public Task Consume(ConsumeContext<OrderCancelled> context)
    {
        logger.LogWarning("[Stock] COMPENSATION — Libération du stock pour {OrderId}", context.Message.OrderId);
        return Task.CompletedTask;
    }
}
