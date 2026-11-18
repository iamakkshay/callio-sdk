using System.Runtime.CompilerServices;
using System.Text.Json;

namespace Clarigoinfotech.Callio.Server;

internal static class Arg
{
    /// <summary>A path segment: required, never "." or "..", percent-encoded.</summary>
    public static string Seg(string? s)
    {
        if (string.IsNullOrEmpty(s) || s == "." || s == "..")
            throw new ArgumentException("Callio: an id / username is required (and cannot be \".\" or \"..\")");
        return Uri.EscapeDataString(s);
    }

    public static string Reason(string? r)
    {
        var t = (r ?? "").Trim();
        if (new System.Globalization.StringInfo(t).LengthInTextElements < 5)
            throw new ArgumentException("Callio: a reason of at least 5 characters is required to fetch a recording");
        return t;
    }

    public static IEnumerable<KeyValuePair<string, object?>> Q(string k, object? v) => new[] { new KeyValuePair<string, object?>(k, v) };
}

internal sealed record UsersEnvelope(List<User> Users);
internal sealed record UserEnvelope(User User);
internal sealed record CreatedUserEnvelope(CreatedUser User);
internal sealed record OrderEnvelope(Order Order);
internal sealed record OrdersEnvelope(List<Order> Orders);
internal sealed record RecordingEnvelope(Recording Recording);
internal sealed record RecordingsEnvelope(List<Recording> Recordings);
internal sealed record TranscriptEnvelope(Transcript Transcript);
internal sealed record GroupEnvelope(Group Group);
internal sealed record GroupsEnvelope(List<Group> Groups);

/// <summary>App users.</summary>
public sealed class Users
{
    private readonly CallioHttp _http;
    internal Users(CallioHttp http) => _http = http;

    /// <summary>Search users.</summary>
    public async Task<IReadOnlyList<User>> ListAsync(ListUsersParams? p = null, CancellationToken ct = default) =>
        (await _http.RequestAsync<UsersEnvelope>(HttpMethod.Get, "/api/v1/users", p?.ToQuery(), null, ct).ConfigureAwait(false))!.Users;

    /// <summary>Create a user. ConflictException (409) if the username exists, PermissionDeniedException (403) at the seat quota.</summary>
    public async Task<CreatedUser> CreateAsync(CreateUserParams p, CancellationToken ct = default) =>
        (await _http.RequestAsync<CreatedUserEnvelope>(HttpMethod.Post, "/api/v1/users", null, p, ct).ConfigureAwait(false))!.User;

    /// <summary>One user.</summary>
    public async Task<User> GetAsync(string username, CancellationToken ct = default) =>
        (await _http.RequestAsync<UserEnvelope>(HttpMethod.Get, "/api/v1/users/" + Arg.Seg(username), null, null, ct).ConfigureAwait(false))!.User;

    /// <summary>Changing the type or disabling ends the user's sessions.</summary>
    public async Task<User> UpdateAsync(string username, UpdateUserParams p, CancellationToken ct = default) =>
        (await _http.RequestAsync<UserEnvelope>(HttpMethod.Patch, "/api/v1/users/" + Arg.Seg(username), null, p, ct).ConfigureAwait(false))!.User;

    /// <summary>Disable the user (ends their sessions).</summary>
    public Task<User> DisableAsync(string username, CancellationToken ct = default) => UpdateAsync(username, new UpdateUserParams { Disabled = true }, ct);

    /// <summary>Enable the user.</summary>
    public Task<User> EnableAsync(string username, CancellationToken ct = default) => UpdateAsync(username, new UpdateUserParams { Disabled = false }, ct);

    /// <summary>End every session the user has open.</summary>
    public async Task<OkResult> SignOutAsync(string username, CancellationToken ct = default) =>
        (await _http.RequestAsync<OkResult>(HttpMethod.Post, "/api/v1/users/" + Arg.Seg(username) + "/sign-out", null, null, ct).ConfigureAwait(false))!;

    /// <summary>PDPL access request: everything held about the user (the platform's shape; it may grow).</summary>
    public async Task<JsonElement> ExportAsync(string username, CancellationToken ct = default) =>
        (await _http.RequestJsonAsync(HttpMethod.Get, "/api/v1/users/" + Arg.Seg(username) + "/export", null, null, ct).ConfigureAwait(false)) ?? default;

    /// <summary>PDPL erasure: deletes the account and its data (recordings on legal hold are kept). Irreversible.</summary>
    public async Task<ErasureResult> DeleteAsync(string username, string reason, CancellationToken ct = default) =>
        (await _http.RequestAsync<ErasureResult>(HttpMethod.Delete, "/api/v1/users/" + Arg.Seg(username), null, new { reason }, ct).ConfigureAwait(false))!;
}

/// <summary>App tokens.</summary>
public sealed class Tokens
{
    private readonly CallioHttp _http;
    private readonly Users _users;
    internal Tokens(CallioHttp http, Users users) { _http = http; _users = users; }

    /// <summary>A short-lived app token for an existing user (ttlSec 60–3600, default 900).</summary>
    public async Task<AppToken> CreateAsync(string username, int? ttlSec = null, CancellationToken ct = default) =>
        await CreateAsync(username, ttlSec, null, ct).ConfigureAwait(false);

    /// <summary>As CreateAsync, for one device: deviceId is the app's device id (its X-Device-Id); null ties the token
    /// to the first device that uses it.</summary>
    public async Task<AppToken> CreateAsync(string username, int? ttlSec, string? deviceId, CancellationToken ct = default) =>
        (await _http.RequestAsync<AppToken>(HttpMethod.Post, "/api/v1/tokens", null, new { username, ttlSec, deviceId }, ct).ConfigureAwait(false))!;

    /// <summary>
    /// The common job: make sure the app user exists, then issue their token. Creates the user if missing (a 409
    /// means they already exist, which is fine). An existing user's display name and type are left as they are;
    /// check UserType on the result if it matters.
    /// </summary>
    public async Task<UserToken> ForUserAsync(string username, ForUserOptions? options = null, CancellationToken ct = default)
    {
        var o = options ?? new ForUserOptions();
        var created = false;
        try
        {
            await _users.CreateAsync(new CreateUserParams { Username = username, DisplayName = o.DisplayName, UserType = o.UserType, Phone = o.Phone }, ct).ConfigureAwait(false);
            created = true;
        }
        catch (ConflictException)
        {
            // already exists
        }
        var t = await CreateAsync(username, o.TtlSec, o.DeviceId, ct).ConfigureAwait(false);
        return new UserToken { Token = t.Token, UserType = t.UserType, ExpiresAt = t.ExpiresAt, Extra = t.Extra, Created = created };
    }
}

/// <summary>Orders: which customer and which agent belong together right now.</summary>
public sealed class Orders
{
    private readonly CallioHttp _http;
    internal Orders(CallioHttp http) => _http = http;

    private async Task<Order> One(HttpMethod m, string path, object? body, CancellationToken ct) =>
        (await _http.RequestAsync<OrderEnvelope>(m, path, null, body, ct).ConfigureAwait(false))!.Order;

    /// <summary>ConflictException if the id exists, ValidationException for an unknown customer/agent or a wrong user type.</summary>
    public Task<Order> CreateAsync(CreateOrderParams p, CancellationToken ct = default) => One(HttpMethod.Post, "/api/v1/orders", p, ct);

    /// <summary>List orders.</summary>
    public async Task<IReadOnlyList<Order>> ListAsync(ListOrdersParams? p = null, CancellationToken ct = default) =>
        (await _http.RequestAsync<OrdersEnvelope>(HttpMethod.Get, "/api/v1/orders", p?.ToQuery(), null, ct).ConfigureAwait(false))!.Orders;

    /// <summary>One order.</summary>
    public Task<Order> GetAsync(string id, CancellationToken ct = default) => One(HttpMethod.Get, "/api/v1/orders/" + Arg.Seg(id), null, ct);

    /// <summary>Reassign (Agent), unassign (Agent = null), close or reopen (Status), relabel.</summary>
    public Task<Order> UpdateAsync(string id, UpdateOrderParams p, CancellationToken ct = default) => One(HttpMethod.Patch, "/api/v1/orders/" + Arg.Seg(id), p, ct);

    /// <summary>Assign an agent; null unassigns.</summary>
    public Task<Order> AssignAsync(string id, string? agent, CancellationToken ct = default) => UpdateAsync(id, new UpdateOrderParams { Agent = agent }, ct);

    /// <summary>Close the order.</summary>
    public Task<Order> CloseAsync(string id, CancellationToken ct = default) => UpdateAsync(id, new UpdateOrderParams { Status = OrderStatus.Closed }, ct);

    /// <summary>Reopen the order.</summary>
    public Task<Order> ReopenAsync(string id, CancellationToken ct = default) => UpdateAsync(id, new UpdateOrderParams { Status = OrderStatus.Active }, ct);
}

/// <summary>An open audio download (stereo Ogg/Opus, caller left). Read <see cref="Body"/> and dispose it promptly.</summary>
public sealed class RecordingAudio : IDisposable, IAsyncDisposable
{
    private readonly StreamedResponse _res;

    internal RecordingAudio(StreamedResponse res, Stream body)
    {
        _res = res;
        Body = body;
        ContentType = res.Response.Content.Headers.ContentType?.ToString() is { Length: > 0 } ctype ? ctype : "audio/ogg";
        ContentLength = res.Response.Content.Headers.ContentLength;
    }

    /// <summary>The audio bytes.</summary>
    public Stream Body { get; }
    /// <summary>The media type (audio/ogg).</summary>
    public string ContentType { get; }
    /// <summary>The length, when known.</summary>
    public long? ContentLength { get; }

    /// <inheritdoc />
    public void Dispose()
    {
        Body.Dispose();
        _res.Dispose();
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        await Body.DisposeAsync().ConfigureAwait(false);
        await _res.DisposeAsync().ConfigureAwait(false);
    }
}

/// <summary>Call recordings. Every audio or transcript fetch needs a reason, written to the recording's access trail.</summary>
public sealed class Recordings
{
    private readonly CallioHttp _http;
    internal Recordings(CallioHttp http) => _http = http;

    /// <summary>Search recordings.</summary>
    public async Task<IReadOnlyList<Recording>> ListAsync(ListRecordingsParams? p = null, CancellationToken ct = default) =>
        (await _http.RequestAsync<RecordingsEnvelope>(HttpMethod.Get, "/api/v1/recordings", p?.ToQuery(), null, ct).ConfigureAwait(false))!.Recordings;

    /// <summary>Recording metadata.</summary>
    public async Task<Recording> GetAsync(string id, CancellationToken ct = default) =>
        (await _http.RequestAsync<RecordingEnvelope>(HttpMethod.Get, "/api/v1/recordings/" + Arg.Seg(id), null, null, ct).ConfigureAwait(false))!.Recording;

    /// <summary>
    /// Open the audio as a stream. The reason (at least 5 characters) is required and goes into the recording's
    /// access trail. Use <c>await using</c>.
    /// </summary>
    public async Task<RecordingAudio> AudioAsync(string id, string reason, CancellationToken ct = default)
    {
        var path = "/api/v1/recordings/" + Arg.Seg(id) + "/audio";
        var q = Arg.Q("reason", Arg.Reason(reason));
        var res = await _http.RequestRawAsync(HttpMethod.Get, path, q, ct).ConfigureAwait(false);
        try
        {
            var body = await res.Response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            return new RecordingAudio(res, body);
        }
        catch
        {
            res.Dispose();
            throw;
        }
    }

    /// <summary>Stream the audio into <paramref name="destination"/>; returns the number of bytes written.</summary>
    public async Task<long> DownloadAsync(string id, Stream destination, string reason, CancellationToken ct = default)
    {
        await using var a = await AudioAsync(id, reason, ct).ConfigureAwait(false);
        var buf = new byte[81920];
        long n = 0;
        int r;
        while ((r = await a.Body.ReadAsync(buf, ct).ConfigureAwait(false)) > 0)
        {
            await destination.WriteAsync(buf.AsMemory(0, r), ct).ConfigureAwait(false);
            n += r;
        }
        return n;
    }

    /// <summary>Stream the audio straight to a file; returns the number of bytes written.</summary>
    public async Task<long> DownloadAsync(string id, string filePath, string reason, CancellationToken ct = default)
    {
        await using var a = await AudioAsync(id, reason, ct).ConfigureAwait(false);
        await using var f = File.Create(filePath);
        long n = 0;
        var buf = new byte[81920];
        int r;
        while ((r = await a.Body.ReadAsync(buf, ct).ConfigureAwait(false)) > 0)
        {
            await f.WriteAsync(buf.AsMemory(0, r), ct).ConfigureAwait(false);
            n += r;
        }
        return n;
    }

    /// <summary>The transcript; same rules as the audio. NotFoundException while it is still being transcribed.</summary>
    public async Task<Transcript> TranscriptAsync(string id, string reason, CancellationToken ct = default) =>
        (await _http.RequestAsync<TranscriptEnvelope>(HttpMethod.Get, "/api/v1/recordings/" + Arg.Seg(id) + "/transcript", Arg.Q("reason", Arg.Reason(reason)), null, ct).ConfigureAwait(false))!.Transcript;
}

/// <summary>Group chats: 2–50 members.</summary>
public sealed class Groups
{
    private readonly CallioHttp _http;
    internal Groups(CallioHttp http) => _http = http;

    private async Task<Group> One(HttpMethod m, string path, object? body, CancellationToken ct) =>
        (await _http.RequestAsync<GroupEnvelope>(m, path, null, body, ct).ConfigureAwait(false))!.Group;

    /// <summary>Create a group chat.</summary>
    public Task<Group> CreateAsync(CreateGroupParams p, CancellationToken ct = default) => One(HttpMethod.Post, "/api/v1/groups", p, ct);

    /// <summary>List group chats.</summary>
    public async Task<IReadOnlyList<Group>> ListAsync(CancellationToken ct = default) =>
        (await _http.RequestAsync<GroupsEnvelope>(HttpMethod.Get, "/api/v1/groups", null, null, ct).ConfigureAwait(false))!.Groups;

    /// <summary>One group chat.</summary>
    public Task<Group> GetAsync(string id, CancellationToken ct = default) => One(HttpMethod.Get, "/api/v1/groups/" + Arg.Seg(id), null, ct);

    /// <summary>Rename, add or remove members. Members added later see messages from when they joined.</summary>
    public Task<Group> UpdateAsync(string id, UpdateGroupParams p, CancellationToken ct = default) => One(HttpMethod.Patch, "/api/v1/groups/" + Arg.Seg(id), p, ct);

    /// <summary>Deletes the group and its messages.</summary>
    public async Task<OkResult> DeleteAsync(string id, CancellationToken ct = default) =>
        (await _http.RequestAsync<OkResult>(HttpMethod.Delete, "/api/v1/groups/" + Arg.Seg(id), null, null, ct).ConfigureAwait(false))!;
}

/// <summary>The event feed (BI).</summary>
public sealed class Events
{
    private readonly CallioHttp _http;
    internal Events(CallioHttp http) => _http = http;

    /// <summary>One page of the event feed, in order. Pass the returned Next as After for the following page.</summary>
    public async Task<EventPage> ListAsync(ListEventsParams? p = null, CancellationToken ct = default) =>
        (await _http.RequestAsync<EventPage>(HttpMethod.Get, "/api/v1/events", p?.ToQuery(), null, ct).ConfigureAwait(false))!;

    /// <summary>Every event after After, page by page, until the feed is caught up. Remember the last Id to resume.</summary>
    public async IAsyncEnumerable<CallioEvent> IterateAsync(ListEventsParams? p = null, [EnumeratorCancellation] CancellationToken ct = default)
    {
        var after = p?.After ?? 0;
        for (;;)
        {
            var page = await ListAsync(new ListEventsParams { After = after, Limit = p?.Limit, Types = p?.Types }, ct).ConfigureAwait(false);
            foreach (var e in page.Events) yield return e;
            if (page.Events.Count == 0 || page.Next <= after) yield break;
            after = page.Next;
        }
    }
}

/// <summary>Call records.</summary>
public sealed class Cdr
{
    private readonly CallioHttp _http;
    internal Cdr(CallioHttp http) => _http = http;

    /// <summary>Call records for the last Days (1–90, default 7): one row per call.</summary>
    public async Task<CdrPage> ListAsync(ListCdrParams? p = null, CancellationToken ct = default) =>
        (await _http.RequestAsync<CdrPage>(HttpMethod.Get, "/api/v1/cdr", p?.ToQuery(), null, ct).ConfigureAwait(false))!;
}
