FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY src/operations/OboSqlServer.Operations.csproj src/operations/
RUN dotnet restore src/operations/OboSqlServer.Operations.csproj
COPY src/operations/ src/operations/
RUN dotnet publish src/operations/OboSqlServer.Operations.csproj -c Release -o /app /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/runtime:8.0
WORKDIR /app
COPY --from=build /app .
COPY src/spa/ /spa/
COPY sql/001-schema-always-encrypted-template.sql /sql/
USER app
ENTRYPOINT ["dotnet", "OboSqlServer.Operations.dll"]
