using System.Security.Claims;
using Microsoft.AspNetCore.Http;
using OboSqlServer.Api.Security;
using OboSqlServer.Api.Services;
using Xunit;

namespace OboSqlServer.Api.Tests;

public sealed class DocumentValidationTests
{
    private static CreateDocumentRequest Request(byte[] payload) =>
        new(Guid.NewGuid(), Guid.NewGuid(), "test.txt", "text/plain", Convert.ToBase64String(payload));

    [Fact]
    public void ExactLimitRoundTrips()
    {
        byte[] data = [1, 2, 3, 4];
        Assert.Equal(data, DocumentValidation.Decode(Request(data), 4));
    }

    [Fact]
    public void OneByteOverLimitIsRejectedEvenWithSameBase64Length()
    {
        var exception = Assert.Throws<BadHttpRequestException>(() => DocumentValidation.Decode(Request([1, 2, 3, 4, 5]), 4));
        Assert.Equal(413, exception.StatusCode);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-base64!")]
    [InlineData("    ")]
    public void InvalidPayloadIsBadRequest(string payload)
    {
        var exception = Assert.Throws<BadHttpRequestException>(() =>
            DocumentValidation.Decode(Request([1]) with { PayloadBase64 = payload }, 100));
        Assert.Equal(400, exception.StatusCode);
    }

    [Fact]
    public void EmptyReceiverIsRejected() =>
        Assert.Throws<BadHttpRequestException>(() =>
            DocumentValidation.Decode(Request([1]) with { ReceiverObjectId = Guid.Empty }, 100));

    [Theory]
    [InlineData("user_impersonation", "bff", "bff", true)]
    [InlineData("other", "bff", "bff", false)]
    [InlineData("user_impersonation", "other", "bff", false)]
    [InlineData("user_impersonation", "cli", null, true)]
    [InlineData("", "bff", "bff", false)]
    public void DelegatedScopeAndOptionalClientAreEnforced(string scope, string client, string? allowed, bool expected)
    {
        var principal = new ClaimsPrincipal(new ClaimsIdentity(
            [new Claim("scp", scope), new Claim("azp", client)], "test"));
        Assert.Equal(expected, DocumentAuthorization.IsAllowed(principal, allowed));
    }
}
