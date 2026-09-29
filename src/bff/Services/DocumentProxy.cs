using System.Net.Http.Headers;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.Identity.Web;

namespace OboSqlServer.Bff.Services;

public sealed class DocumentProxy(
    IHttpClientFactory clients,
    IApiTokenProvider tokens,
    IAntiforgery antiforgery,
    ILogger<DocumentProxy> logger)
{
    public async Task ForwardAsync(HttpContext context, string relativePath)
    {
        if (HttpMethods.IsPost(context.Request.Method))
        {
            if (context.Request.ContentLength > 15 * 1024 * 1024)
            {
                context.Response.StatusCode = StatusCodes.Status413PayloadTooLarge;
                return;
            }
            try
            {
                await antiforgery.ValidateRequestAsync(context);
            }
            catch (AntiforgeryValidationException)
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                await context.Response.WriteAsJsonAsync(new { error = "Invalid antiforgery token." });
                return;
            }

            if (!context.Request.HasJsonContentType())
            {
                context.Response.StatusCode = StatusCodes.Status415UnsupportedMediaType;
                return;
            }
        }

        string token;
        try
        {
            token = await tokens.GetAsync(context.User);
        }
        catch (MicrosoftIdentityWebChallengeUserException)
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await context.Response.WriteAsJsonAsync(new { error = "Sign in again to continue." });
            return;
        }

        using var request = new HttpRequestMessage(new HttpMethod(context.Request.Method), relativePath);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var correlationId = Guid.NewGuid().ToString();
        request.Headers.Add("x-correlation-id", correlationId);
        context.Response.Headers["x-correlation-id"] = correlationId;
        if (HttpMethods.IsPost(context.Request.Method))
        {
            request.Content = new StreamContent(context.Request.Body);
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        }

        try
        {
            using var client = clients.CreateClient("api");
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
            // ResponseHeadersRead ends HttpClient's timeout when headers arrive, not when the body finishes.
            deadline.CancelAfter(client.Timeout);
            using var response = await client.SendAsync(
                request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            context.Response.StatusCode = (int)response.StatusCode;
            // Never relay cookies, token challenges, redirects or arbitrary upstream headers.
            if (!response.IsSuccessStatusCode)
            {
                await context.Response.WriteAsJsonAsync(
                    new { error = $"API returned {(int)response.StatusCode}.", correlationId },
                    cancellationToken: deadline.Token);
                return;
            }
            context.Response.ContentType = "application/json";
            await response.Content.CopyToAsync(context.Response.Body, deadline.Token);
        }
        catch (HttpRequestException)
        {
            logger.LogWarning("API connection failed. CorrelationId={CorrelationId}", correlationId);
            if (context.Response.HasStarted) { context.Abort(); return; }
            context.Response.StatusCode = StatusCodes.Status502BadGateway;
            await context.Response.WriteAsJsonAsync(new { error = "API unavailable.", correlationId });
        }
        catch (OperationCanceledException) when (!context.RequestAborted.IsCancellationRequested)
        {
            logger.LogWarning("API request timed out. CorrelationId={CorrelationId}", correlationId);
            if (context.Response.HasStarted) { context.Abort(); return; }
            context.Response.StatusCode = StatusCodes.Status504GatewayTimeout;
        }
    }
}
