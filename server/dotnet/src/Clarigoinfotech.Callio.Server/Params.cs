using System.Globalization;

namespace Clarigoinfotech.Callio.Server;

/// <summary>
/// Base of PATCH bodies: only properties you set are sent, and a property set to null is sent as JSON null
/// (e.g. <c>new UpdateOrderParams { Agent = null }</c> unassigns).
/// </summary>
public abstract class PatchParams
{
    internal readonly Dictionary<string, object?> Fields = new();

    /// <summary>Sets a field by its JSON name, including ones this SDK version doesn't know yet.</summary>
    public void Set(string field, object? value) => Fields[field] = value;

    /// <summary>Reads a field that was set (default otherwise).</summary>
    protected T? Get<T>(string field) => Fields.TryGetValue(field, out var v) && v is T t ? t : default;
}

/// <summary>The body of <c>Users.CreateAsync</c>.</summary>
public sealed class CreateUserParams
{
    /// <summary>Required: letters, digits, '.', '_', '-'.</summary>
    public required string Username { get; init; }
    /// <summary>The display name.</summary>
    public string? DisplayName { get; init; }
    /// <summary>customer or agent.</summary>
    public string? UserType { get; init; }
    /// <summary>A password for the console login; without one, a random InitialPassword is returned once.</summary>
    public string? LoginPassword { get; init; }
    /// <summary>A phone fallback number.</summary>
    public string? Phone { get; init; }
}

/// <summary>The body of <c>Users.UpdateAsync</c>. Setting Segment or Phone to null clears it.</summary>
public sealed class UpdateUserParams : PatchParams
{
    /// <summary>The display name.</summary>
    public string? DisplayName { get => Get<string>("displayName"); set => Set("displayName", value); }
    /// <summary>customer or agent. Changing it ends the user's sessions.</summary>
    public string? UserType { get => Get<string>("userType"); set => Set("userType", value); }
    /// <summary>Disabling ends the user's sessions.</summary>
    public bool? Disabled { get => Fields.TryGetValue("disabled", out var v) ? (bool?)v : null; set => Set("disabled", value); }
    /// <summary>The segment (null clears it).</summary>
    public string? Segment { get => Get<string>("segment"); set => Set("segment", value); }
    /// <summary>The phone fallback number (null clears it).</summary>
    public string? Phone { get => Get<string>("phone"); set => Set("phone", value); }
}

/// <summary>Filters for <c>Users.ListAsync</c>.</summary>
public sealed class ListUsersParams
{
    /// <summary>Search text.</summary>
    public string? Q { get; init; }
    /// <summary>customer or agent.</summary>
    public string? Type { get; init; }
    /// <summary>active or disabled.</summary>
    public string? Status { get; init; }
    /// <summary>The segment.</summary>
    public string? Segment { get; init; }
    /// <summary>Page size.</summary>
    public int? Limit { get; init; }

    internal IEnumerable<KeyValuePair<string, object?>> ToQuery() => new KeyValuePair<string, object?>[]
    {
        new("q", Q), new("type", Type), new("status", Status), new("segment", Segment), new("limit", Limit),
    };
}

/// <summary>Options for <c>Tokens.ForUserAsync</c>.</summary>
public sealed class ForUserOptions
{
    /// <summary>Used when the user is created.</summary>
    public string? DisplayName { get; init; }
    /// <summary>customer or agent; used when the user is created.</summary>
    public string? UserType { get; init; }
    /// <summary>60–3600 s (default 900).</summary>
    public int? TtlSec { get; init; }
    /// <summary>The app's device id (its X-Device-Id): the token works on that device only.</summary>
    public string? DeviceId { get; init; }
    /// <summary>Used when the user is created.</summary>
    public string? Phone { get; init; }
}

/// <summary>The body of <c>Orders.CreateAsync</c>.</summary>
public sealed class CreateOrderParams
{
    /// <summary>Your order id.</summary>
    public required string Id { get; init; }
    /// <summary>The customer's username.</summary>
    public required string Customer { get; init; }
    /// <summary>The agent's username.</summary>
    public string? Agent { get; init; }
    /// <summary>A label.</summary>
    public string? Label { get; init; }
}

/// <summary>The body of <c>Orders.UpdateAsync</c>: Agent = "drv-7" reassigns, Agent = null unassigns, Status = "closed" closes.</summary>
public sealed class UpdateOrderParams : PatchParams
{
    /// <summary>The agent (null unassigns).</summary>
    public string? Agent { get => Get<string>("agent"); set => Set("agent", value); }
    /// <summary>active or closed.</summary>
    public string? Status { get => Get<string>("status"); set => Set("status", value); }
    /// <summary>A label (null clears it).</summary>
    public string? Label { get => Get<string>("label"); set => Set("label", value); }
}

/// <summary>Filters for <c>Orders.ListAsync</c>.</summary>
public sealed class ListOrdersParams
{
    /// <summary>active or closed.</summary>
    public string? Status { get; init; }
    /// <summary>A username on either side.</summary>
    public string? User { get; init; }
    /// <summary>Page size.</summary>
    public int? Limit { get; init; }

    internal IEnumerable<KeyValuePair<string, object?>> ToQuery() => new KeyValuePair<string, object?>[]
    {
        new("status", Status), new("user", User), new("limit", Limit),
    };
}

/// <summary>Filters for <c>Recordings.ListAsync</c>.</summary>
public sealed class ListRecordingsParams
{
    /// <summary>From (sent as ISO 8601 UTC).</summary>
    public DateTimeOffset? From { get; init; }
    /// <summary>To (sent as ISO 8601 UTC).</summary>
    public DateTimeOffset? To { get; init; }
    /// <summary>Extension of either party.</summary>
    public string? User { get; init; }
    /// <summary>The call id.</summary>
    public string? CallId { get; init; }
    /// <summary>The order id.</summary>
    public string? OrderId { get; init; }
    /// <summary>Seconds.</summary>
    public int? MinDuration { get; init; }
    /// <summary>Seconds.</summary>
    public int? MaxDuration { get; init; }
    /// <summary>stored (default), deleted or all.</summary>
    public string? Status { get; init; }
    /// <summary>Page size.</summary>
    public int? Limit { get; init; }

    internal IEnumerable<KeyValuePair<string, object?>> ToQuery() => new KeyValuePair<string, object?>[]
    {
        new("from", From), new("to", To), new("user", User), new("callId", CallId), new("orderId", OrderId),
        new("minDuration", MinDuration), new("maxDuration", MaxDuration), new("status", Status), new("limit", Limit),
    };
}

/// <summary>The body of <c>Groups.CreateAsync</c>: 2–50 members.</summary>
public sealed class CreateGroupParams
{
    /// <summary>Your group id.</summary>
    public required string Id { get; init; }
    /// <summary>The name.</summary>
    public required string Name { get; init; }
    /// <summary>2–50 usernames.</summary>
    public required IReadOnlyList<string> Members { get; init; }
}

/// <summary>The body of <c>Groups.UpdateAsync</c>.</summary>
public sealed class UpdateGroupParams
{
    /// <summary>A new name.</summary>
    public string? Name { get; init; }
    /// <summary>Usernames to add.</summary>
    public IReadOnlyList<string>? Add { get; init; }
    /// <summary>Usernames to remove.</summary>
    public IReadOnlyList<string>? Remove { get; init; }
}

/// <summary>Filters for <c>Events.ListAsync</c> / <c>Events.IterateAsync</c>.</summary>
public sealed class ListEventsParams
{
    /// <summary>Events after this id.</summary>
    public long? After { get; init; }
    /// <summary>Page size.</summary>
    public int? Limit { get; init; }
    /// <summary>Type prefixes, e.g. ["call.", "chat."].</summary>
    public IReadOnlyList<string>? Types { get; init; }

    internal IEnumerable<KeyValuePair<string, object?>> ToQuery() => new KeyValuePair<string, object?>[]
    {
        new("after", After), new("limit", Limit), new("types", Types),
    };
}

/// <summary>Filters for <c>Cdr.ListAsync</c>.</summary>
public sealed class ListCdrParams
{
    /// <summary>1–90 (default 7).</summary>
    public int? Days { get; init; }
    /// <summary>customer, agent or guest.</summary>
    public string? Type { get; init; }

    internal IEnumerable<KeyValuePair<string, object?>> ToQuery() => new KeyValuePair<string, object?>[] { new("days", Days), new("type", Type) };
}

internal static class Query
{
    public static string Encode(IEnumerable<KeyValuePair<string, object?>>? q)
    {
        if (q is null) return "";
        var parts = new List<string>();
        foreach (var (k, v) in q)
        {
            var s = Value(v);
            if (s is null) continue;
            parts.Add(System.Net.WebUtility.UrlEncode(k) + "=" + System.Net.WebUtility.UrlEncode(s));
        }
        return parts.Count == 0 ? "" : "?" + string.Join("&", parts);
    }

    private static string? Value(object? v) => v switch
    {
        null => null,
        string s => s.Length == 0 ? null : s,
        bool b => b ? "true" : "false",
        DateTimeOffset d => d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture),
        DateTime d => (d.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(d, DateTimeKind.Utc) : d.ToUniversalTime()).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture),
        DateOnly d => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        IEnumerable<string> list => list.Any() ? string.Join(",", list) : null,
        IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
        _ => v.ToString() is { Length: > 0 } s2 ? s2 : null,
    };
}
