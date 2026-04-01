FROM mcr.microsoft.com/dotnet/aspnet:10.0-preview AS base
WORKDIR /app

FROM mcr.microsoft.com/dotnet/sdk:10.0-preview AS build
WORKDIR /src
COPY Contracts/Contracts.csproj Contracts/
COPY PaymentService/PaymentService.csproj PaymentService/
RUN dotnet restore PaymentService/PaymentService.csproj
COPY . .
RUN dotnet publish PaymentService/PaymentService.csproj -c Release -o /app/publish

FROM base AS final
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "PaymentService.dll"]
