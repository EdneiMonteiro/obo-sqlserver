using System.Security.Cryptography;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.Extensions.Caching.Memory;

namespace OboSqlServer.Bff.Security;

// One replica per BFF: restart invalidates sessions and the matching in-memory MSAL cache.
public sealed class ServerTicketStore(IMemoryCache cache) : ITicketStore
{
    public Task<string> StoreAsync(AuthenticationTicket ticket)
    {
        var key = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        return StoreNewAsync(key, ticket);
    }

    private async Task<string> StoreNewAsync(string key, AuthenticationTicket ticket)
    {
        await RenewAsync(key, ticket);
        return key;
    }

    public Task RenewAsync(string key, AuthenticationTicket ticket)
    {
        var expiry = ticket.Properties.ExpiresUtc ?? DateTimeOffset.UtcNow.AddMinutes(30);
        cache.Set("ticket:" + key, TicketSerializer.Default.Serialize(ticket), expiry);
        return Task.CompletedTask;
    }

    public Task<AuthenticationTicket?> RetrieveAsync(string key)
    {
        var bytes = cache.Get<byte[]>("ticket:" + key);
        return Task.FromResult(bytes is null ? null : TicketSerializer.Default.Deserialize(bytes));
    }

    public Task RemoveAsync(string key)
    {
        cache.Remove("ticket:" + key);
        return Task.CompletedTask;
    }
}
