namespace SagaOrchestrator.Models;

// === Input / Output du workflow ===
public record OrderSagaInput(string ProductId, int Quantity);
public record OrderSagaResult(Guid OrderId, string Status, string? Reason);

// === DTOs de réponse des services ===
public record CreateOrderResponse(Guid Id, string ProductId, int Quantity, string Status);
public record ErrorResponse(string Reason);
