FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY src/bff/OboSqlServer.Bff.csproj src/bff/
RUN dotnet restore src/bff/OboSqlServer.Bff.csproj
COPY src/bff/ src/bff/
RUN dotnet publish src/bff/OboSqlServer.Bff.csproj -c Release -o /app /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=build /app .
ENV ASPNETCORE_HTTP_PORTS=8080
USER app
EXPOSE 8080
ENTRYPOINT ["dotnet", "OboSqlServer.Bff.dll"]
