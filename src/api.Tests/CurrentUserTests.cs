using OboSqlServer.Api.Security;
using System.Security.Claims;
using Xunit;

namespace OboSqlServer.Api.Tests;

public sealed class CurrentUserTests
{
    [Fact]
    public void FromClaimsPrincipalReadsTenantAndObjectIds()
    {
        var tenantId = Guid.NewGuid();
        var objectId = Guid.NewGuid();
        var principal = new ClaimsPrincipal(new ClaimsIdentity(new[]
        {
            new Claim("tid", tenantId.ToString()),
            new Claim("oid", objectId.ToString()),
            new Claim("name", "Reader")
        }, "test"));

        var user = CurrentUser.FromClaimsPrincipal(principal);

        Assert.Equal(tenantId, user.TenantId);
        Assert.Equal(objectId, user.ObjectId);
        Assert.Equal("Reader", user.DisplayName);
    }

    [Fact]
    public void FromClaimsPrincipalRejectsMissingObjectId()
    {
        var principal = new ClaimsPrincipal(new ClaimsIdentity(new[]
        {
            new Claim("tid", Guid.NewGuid().ToString())
        }, "test"));

        Assert.Throws<UnauthorizedAccessException>(() => CurrentUser.FromClaimsPrincipal(principal));
    }
}
