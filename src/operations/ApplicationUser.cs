using System.Text.Json;

namespace OboSqlServer.Operations;

public sealed record ApplicationUser(Guid ObjectId, bool CanSend, bool CanRead)
{
    public static IReadOnlyList<ApplicationUser> Parse(string json)
    {
        var users = JsonSerializer.Deserialize<ApplicationUser?[]>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        }) ?? throw new InvalidOperationException("APPLICATION_USERS must be a JSON array.");
        foreach (var user in users)
        {
            if (user is null || user.ObjectId == Guid.Empty || (!user.CanSend && !user.CanRead))
                throw new InvalidOperationException("Application users require an object ID and at least one document permission.");
        }
        return users.Select(user => user!).GroupBy(user => user.ObjectId)
            .Select(group => new ApplicationUser(group.Key, group.Any(user => user.CanSend), group.Any(user => user.CanRead)))
            .ToArray();
    }
}
