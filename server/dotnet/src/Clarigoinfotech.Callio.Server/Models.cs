using System.Text.Json;
using System.Text.Json.Serialization;

namespace Clarigoinfotech.Callio.Server;

// Models returned by the Callio tenant API (/api/v1). Property names map to the camelCase JSON on the wire;
// timestamps are ISO 8601 strings, as the API sends them. Fields the platform adds later land in Extra.

/// <summary>User types.</summary>
public static class UserType
{
    /// <summary>A customer.</summary>
    public const string Customer = "customer";
    /// <summary>An agent (driver, support staff…).</summary>
    public const string Agent = "agent";
    /// <summary>A guest (web visitor).</summary>
    public const string Guest = "guest";
}

/// <summary>Order statuses.</summary>
public static class OrderStatus
{
    /// <summary>Open.</summary>
    public const string Active = "active";
    /// <summary>Closed.</summary>
    public const string Closed = "closed";
}

/// <summary>Base of every model: unknown fields are kept.</summary>
public abstract record ApiModel
{
    /// <summary>Fields this SDK version doesn't map.</summary>
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; init; }
}

/// <summary>A Callio user.</summary>
public record User : ApiModel
{
    /// <summary>The username.</summary>
    public string Username { get; init; } = "";
    /// <summary>The display name.</summary>
    public string? DisplayName { get; init; }
    /// <summary>customer, agent or guest.</summary>
    public string UserType { get; init; } = "";
    /// <summary>The user's SIP extension.</summary>
    public string Extension { get; init; } = "";
    /// <summary>The segment.</summary>
    public string? Segment { get; init; }
    /// <summary>Disabled users cannot sign in.</summary>
    public bool Disabled { get; init; }
    /// <summary>Masked phone fallback number (only on get/create/update, not in list results).</summary>
    public string? Phone { get; init; }
}

/// <summary>The result of <c>Users.CreateAsync</c>.</summary>
public record CreatedUser : User
{
    /// <summary>Returned once, when the user was created without a LoginPassword.</summary>
    public string? InitialPassword { get; init; }
}

/// <summary>A short-lived app token.</summary>
public record AppToken : ApiModel
{
    /// <summary>A JWT for the app SDKs.</summary>
    public string Token { get; init; } = "";
    /// <summary>The user's type.</summary>
    public string UserType { get; init; } = "";
    /// <summary>ISO 8601.</summary>
    public string ExpiresAt { get; init; } = "";
}

/// <summary>The result of <c>Tokens.ForUserAsync</c>.</summary>
public record UserToken : AppToken
{
    /// <summary>True when ForUserAsync created the user on this call.</summary>
    public bool Created { get; init; }
}

/// <summary>An order: a customer and (optionally) the agent assigned right now.</summary>
public record Order : ApiModel
{
    /// <summary>Your id.</summary>
    public string Id { get; init; } = "";
    /// <summary>The customer's username.</summary>
    public string Customer { get; init; } = "";
    /// <summary>The agent's username; null when unassigned.</summary>
    public string? Agent { get; init; }
    /// <summary>active or closed.</summary>
    public string Status { get; init; } = "";
    /// <summary>A label.</summary>
    public string? Label { get; init; }
    /// <summary>ISO 8601.</summary>
    public string CreatedAt { get; init; } = "";
    /// <summary>ISO 8601.</summary>
    public string UpdatedAt { get; init; } = "";
    /// <summary>ISO 8601, when closed.</summary>
    public string? ClosedAt { get; init; }
}

/// <summary>A recording's transcript state.</summary>
public record TranscriptStatus : ApiModel
{
    /// <summary>The state.</summary>
    public string Status { get; init; } = "";
    /// <summary>The detected language.</summary>
    public string? Language { get; init; }
    /// <summary>The failure, if any.</summary>
    public string? Error { get; init; }
}

/// <summary>A call recording's metadata.</summary>
public record Recording : ApiModel
{
#pragma warning disable CS1591
    public string Id { get; init; } = "";
    public string Tenant { get; init; } = "";
    public string? CallRef { get; init; }
    public string? Caller { get; init; }
    public string? Callee { get; init; }
    public string? CallType { get; init; }
    public string? OrderId { get; init; }
    public string? StartedAt { get; init; }
    public double DurationSec { get; init; }
    public long Bytes { get; init; }
    public string? Format { get; init; }
    /// <summary>stored or deleted.</summary>
    public string Status { get; init; } = "";
    public bool LegalHold { get; init; }
    public string? HoldReason { get; init; }
    public string? RetainUntil { get; init; }
    public string? DeletedAt { get; init; }
    public string? DeleteReason { get; init; }
    public string CreatedAt { get; init; } = "";
    public TranscriptStatus? Transcript { get; init; }
#pragma warning restore CS1591
}

/// <summary>One timed piece of a transcript.</summary>
public record TranscriptSegment : ApiModel
{
    /// <summary>Seconds.</summary>
    public double Start { get; init; }
    /// <summary>Seconds.</summary>
    public double End { get; init; }
    /// <summary>The words.</summary>
    public string Text { get; init; } = "";
}

/// <summary>A recording's transcript.</summary>
public record Transcript : ApiModel
{
    /// <summary>The full text.</summary>
    public string Text { get; init; } = "";
    /// <summary>The language.</summary>
    public string? Language { get; init; }
    /// <summary>Timed segments.</summary>
    public List<TranscriptSegment>? Segments { get; init; }
}

/// <summary>A member of a group chat.</summary>
public record GroupMember : ApiModel
{
#pragma warning disable CS1591
    public string Username { get; init; } = "";
    public string? DisplayName { get; init; }
    public string UserType { get; init; } = "";
    public string SipUser { get; init; } = "";
#pragma warning restore CS1591
}

/// <summary>A group chat.</summary>
public record Group : ApiModel
{
#pragma warning disable CS1591
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string CreatedAt { get; init; } = "";
    public List<GroupMember> Members { get; init; } = new();
#pragma warning restore CS1591
}

/// <summary>One entry of the event feed.</summary>
public record CallioEvent : ApiModel
{
#pragma warning disable CS1591
    public long Id { get; init; }
    public string Type { get; init; } = "";
    public string? CallId { get; init; }
    public string? From { get; init; }
    public string? To { get; init; }
    public string? FromType { get; init; }
    public string? ToType { get; init; }
    public string? OrderId { get; init; }
    public string At { get; init; } = "";
    public JsonElement? Payload { get; init; }
#pragma warning restore CS1591
}

/// <summary>One page of the event feed. Pass <see cref="Next"/> as After for the following page.</summary>
public record EventPage : ApiModel
{
    /// <summary>The events, in order.</summary>
    public List<CallioEvent> Events { get; init; } = new();
    /// <summary>The cursor for the next page.</summary>
    public long Next { get; init; }
}

/// <summary>One row of the call records.</summary>
public record CallRecord : ApiModel
{
#pragma warning disable CS1591
    public string CallId { get; init; } = "";
    public string Tenant { get; init; } = "";
    public string? From { get; init; }
    public string? To { get; init; }
    public string? FromType { get; init; }
    public string? ToType { get; init; }
    public string Direction { get; init; } = "";
    public bool Support { get; init; }
    public string? OrderId { get; init; }
    public string? EntryPoint { get; init; }
    public string Outcome { get; init; } = "";
    public string EndReason { get; init; } = "";
    public double DurationSec { get; init; }
    public double? AnswerSec { get; init; }
    public string? StartedAt { get; init; }
    public string? AnsweredAt { get; init; }
    public string? EndedAt { get; init; }
    public JsonElement? Quality { get; init; }
    public JsonElement? Client { get; init; }
#pragma warning restore CS1591
}

/// <summary>Call records for a window of days.</summary>
public record CdrPage : ApiModel
{
    /// <summary>The window.</summary>
    public int Days { get; init; }
    /// <summary>One row per call.</summary>
    public List<CallRecord> Calls { get; init; } = new();
}

/// <summary>The result of a PDPL erasure.</summary>
public record ErasureResult : ApiModel
{
    /// <summary>True.</summary>
    public bool Ok { get; init; }
    /// <summary>The pseudonym that replaced the user in records that are kept (events, orders, others' messages).</summary>
    public string Alias { get; init; } = "";
    /// <summary>Counts of removed records.</summary>
    public Dictionary<string, long> Removed { get; init; } = new();
    /// <summary>Recordings kept because of a legal hold.</summary>
    public List<string> RecordingsKeptOnLegalHold { get; init; } = new();
}

/// <summary>An acknowledgement.</summary>
public record OkResult : ApiModel
{
    /// <summary>True.</summary>
    public bool Ok { get; init; }
}
