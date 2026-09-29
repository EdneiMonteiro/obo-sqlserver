using System.Net;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.DependencyInjection;
using OboSqlServer.Bff.Services;
using Xunit;

namespace OboSqlServer.Bff.Tests;

public sealed class DocumentProxyTests
{
    [Theory]
    [InlineData("headers")]
    [InlineData("body")]
    public async Task TimeoutCoversHeadersAndResponseBody(string phase)
    {
        using var harness = new ProxyHarness(phase, TimeSpan.FromMilliseconds(200));

        await harness.ForwardAsync().WaitAsync(TimeSpan.FromSeconds(5));

        Assert.True(harness.Blocked.Task.IsCompletedSuccessfully);
        Assert.Equal(StatusCodes.Status504GatewayTimeout, harness.Context.Response.StatusCode);
        Assert.Empty(harness.Body.ToArray());
        Assert.False(harness.Lifetime.Aborted);
    }

    [Fact]
    public async Task TimeoutAfterPartialResponseAbortsInsteadOfReturningSuccess()
    {
        using var harness = new ProxyHarness("partial", TimeSpan.FromMilliseconds(200));

        await harness.ForwardAsync().WaitAsync(TimeSpan.FromSeconds(5));

        Assert.True(harness.Context.Response.HasStarted);
        Assert.Equal("{", System.Text.Encoding.UTF8.GetString(harness.Body.ToArray()));
        Assert.True(harness.Lifetime.Aborted);
        Assert.Equal(StatusCodes.Status200OK, harness.Context.Response.StatusCode);
    }

    [Theory]
    [InlineData("client")]
    [InlineData("client-error")]
    public async Task TimeoutAlsoCancelsWritingToASlowClient(string phase)
    {
        using var harness = new ProxyHarness(phase, TimeSpan.FromMilliseconds(200));

        await harness.ForwardAsync().WaitAsync(TimeSpan.FromSeconds(5));

        Assert.True(harness.Blocked.Task.IsCompletedSuccessfully);
        Assert.True(harness.Context.Response.HasStarted);
        Assert.True(harness.Lifetime.Aborted);
    }

    [Theory]
    [InlineData("headers")]
    [InlineData("body")]
    public async Task ClientCancellationIsNotReportedAsUpstreamTimeout(string phase)
    {
        using var harness = new ProxyHarness(phase, Timeout.InfiniteTimeSpan);
        var forwarding = harness.ForwardAsync();
        await harness.Blocked.Task.WaitAsync(TimeSpan.FromSeconds(5));

        harness.Lifetime.Cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => forwarding.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.NotEqual(StatusCodes.Status504GatewayTimeout, harness.Context.Response.StatusCode);
        Assert.False(harness.Lifetime.Aborted);
    }

    [Fact]
    public async Task SuccessfulResponseIsCopiedWithoutChangingItsBytes()
    {
        using var harness = new ProxyHarness("complete", TimeSpan.FromSeconds(5));

        await harness.ForwardAsync().WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(StatusCodes.Status200OK, harness.Context.Response.StatusCode);
        Assert.Equal("{\"payloadBase64\":\"AAH/\"}", System.Text.Encoding.UTF8.GetString(harness.Body.ToArray()));
        Assert.False(harness.Lifetime.Aborted);
    }

    private sealed class ProxyHarness : IDisposable
    {
        private readonly ServiceProvider services;
        public DefaultHttpContext Context { get; } = new();
        public MemoryStream Body { get; }
        public RequestLifetime Lifetime { get; } = new();
        public TaskCompletionSource Blocked { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public ProxyHarness(string phase, TimeSpan timeout)
        {
            var response = new StartedResponse();
            Context.Features.Set<IHttpResponseFeature>(response);
            Context.Features.Set<IHttpRequestLifetimeFeature>(Lifetime);
            Context.Request.Method = HttpMethods.Get;
            Body = phase.StartsWith("client", StringComparison.Ordinal)
                ? new SlowClientStream(Blocked, response)
                : new MemoryStream();
            Context.Response.Body = Body;
            var collection = new ServiceCollection();
            collection.AddLogging();
            collection.AddAntiforgery();
            collection.AddSingleton<IApiTokenProvider, FakeTokens>();
            collection.AddTransient<DocumentProxy>();
            collection.AddHttpClient("api", client =>
            {
                client.BaseAddress = new Uri("http://api.example.test/");
                client.Timeout = timeout;
            }).ConfigurePrimaryHttpMessageHandler(() => new DelayedUpstream(phase, Blocked, response));
            services = collection.BuildServiceProvider();
            Context.RequestServices = services;
        }

        public Task ForwardAsync() => services.GetRequiredService<DocumentProxy>().ForwardAsync(Context, "documents/example");

        public void Dispose()
        {
            Lifetime.Cancellation.Cancel();
            services.Dispose();
            Body.Dispose();
            Lifetime.Cancellation.Dispose();
        }
    }

    private sealed class StartedResponse : HttpResponseFeature
    {
        public bool Started { get; set; }
        public override bool HasStarted => Started;
    }

    private sealed class RequestLifetime : IHttpRequestLifetimeFeature
    {
        public CancellationTokenSource Cancellation { get; } = new();
        public CancellationToken RequestAborted { get => Cancellation.Token; set => throw new NotSupportedException(); }
        public bool Aborted { get; private set; }
        public void Abort()
        {
            Aborted = true;
            Cancellation.Cancel();
        }
    }

    private sealed class DelayedUpstream(string phase, TaskCompletionSource blocked, StartedResponse response) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (phase == "headers")
            {
                blocked.TrySetResult();
                await Task.Delay(Timeout.Infinite, cancellationToken);
            }
            return new HttpResponseMessage(phase == "client-error" ? HttpStatusCode.ServiceUnavailable : HttpStatusCode.OK)
            {
                Content = phase is "body" or "partial"
                    ? new DelayedContent(phase == "partial", blocked, response)
                    : new StringContent("{\"payloadBase64\":\"AAH/\"}")
            };
        }
    }

    private sealed class SlowClientStream(TaskCompletionSource blocked, StartedResponse response) : MemoryStream
    {
        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            WaitForCancellationAsync(cancellationToken);

        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default) =>
            new(WaitForCancellationAsync(cancellationToken));

        private Task WaitForCancellationAsync(CancellationToken cancellationToken)
        {
            response.Started = true;
            blocked.TrySetResult();
            return Task.Delay(Timeout.Infinite, cancellationToken);
        }
    }

    private sealed class DelayedContent(bool partial, TaskCompletionSource blocked, StartedResponse response) : HttpContent
    {
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
            SerializeToStreamAsync(stream, context, CancellationToken.None);

        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken cancellationToken)
        {
            if (partial)
            {
                await stream.WriteAsync("{"u8.ToArray(), cancellationToken);
                response.Started = true;
            }
            blocked.TrySetResult();
            await Task.Delay(Timeout.Infinite, cancellationToken);
        }

        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }
    }
}
