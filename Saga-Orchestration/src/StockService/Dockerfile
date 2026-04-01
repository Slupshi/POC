FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY nuget.config .
COPY src/StockService/StockService.csproj src/StockService/
RUN dotnet restore src/StockService/StockService.csproj
COPY src/StockService/ src/StockService/
RUN dotnet publish src/StockService/StockService.csproj -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
EXPOSE 8080
ENTRYPOINT ["dotnet", "StockService.dll"]
