namespace Contracts;

// === Événements métier ===
public record OrderCreated(Guid OrderId, string ProductId, int Quantity);
public record StockReserved(Guid OrderId);
public record StockReservationFailed(Guid OrderId, string Reason);
public record PaymentCompleted(Guid OrderId);
public record PaymentFailed(Guid OrderId, string Reason);

// === Événements de compensation ===
public record OrderCancelled(Guid OrderId);
