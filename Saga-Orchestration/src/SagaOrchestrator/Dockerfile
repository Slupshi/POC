FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY nuget.config .
COPY src/SagaOrchestrator/SagaOrchestrator.csproj src/SagaOrchestrator/
RUN dotnet restore src/SagaOrchestrator/SagaOrchestrator.csproj
COPY src/SagaOrchestrator/ src/SagaOrchestrator/
RUN dotnet publish src/SagaOrchestrator/SagaOrchestrator.csproj -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
EXPOSE 8080
ENTRYPOINT ["dotnet", "SagaOrchestrator.dll"]
