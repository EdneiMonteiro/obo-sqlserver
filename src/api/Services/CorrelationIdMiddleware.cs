namespace OboSqlServer.Api.Services;

public sealed class CorrelationIdMiddleware(RequestDelegate next)
{
    public const string HeaderName = "x-correlation-id";

    public async Task InvokeAsync(HttpContext context)
    {
        var correlationId = context.Request.Headers.TryGetValue(HeaderName, out var headerValue) &&
                            Guid.TryParse(headerValue, out var parsed)
            ? parsed
            : Guid.NewGuid();

        context.Items[HeaderName] = correlationId;
        context.Response.Headers[HeaderName] = correlationId.ToString();

        await next(context);
    }
}

