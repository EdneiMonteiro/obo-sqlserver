using OboSqlServer.Operations;
using Xunit;

namespace OboSqlServer.Operations.Tests;

public sealed class ApplicationUserTests
{
    [Fact]
    public void EmptyArrayDoesNotInventAnAdministratorOrTestUser() =>
        Assert.Empty(ApplicationUser.Parse("[]"));

    [Fact]
    public void CombinesOnlyTheExplicitPermissionsForTheSameUser()
    {
        var id = Guid.NewGuid();
        var users = ApplicationUser.Parse($$"""
            [{"objectId":"{{id}}","canSend":true,"canRead":false},
             {"objectId":"{{id}}","canSend":false,"canRead":true}]
            """);
        Assert.Equal(new ApplicationUser(id, true, true), Assert.Single(users));
    }

    [Fact]
    public void SenderDoesNotGainReadPermission()
    {
        var id = Guid.NewGuid();
        Assert.Equal(new ApplicationUser(id, true, false),
            Assert.Single(ApplicationUser.Parse($$"""[{"objectId":"{{id}}","canSend":true}]""")));
    }

    [Theory]
    [InlineData("null")]
    [InlineData("[null]")]
    [InlineData("[{}]")]
    [InlineData("""[{"objectId":"11111111-1111-1111-1111-111111111111"}]""")]
    public void RejectsIncompleteConfiguration(string json) =>
        Assert.Throws<InvalidOperationException>(() => ApplicationUser.Parse(json));
}
