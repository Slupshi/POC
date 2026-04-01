FROM mcr.microsoft.com/dotnet/aspnet:10.0-preview AS base
WORKDIR /app

FROM mcr.microsoft.com/dotnet/sdk:10.0-preview AS build
WORKDIR /src
COPY Contracts/Contracts.csproj Contracts/
COPY StockService/StockService.csproj StockService/
RUN dotnet restore StockService/StockService.csproj
COPY . .
RUN dotnet publish StockService/StockService.csproj -c Release -o /app/publish

FROM base AS final
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "StockService.dll"]
