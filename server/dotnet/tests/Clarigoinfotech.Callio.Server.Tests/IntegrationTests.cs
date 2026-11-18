// Integration test against a running Callio stack. It signs in to the admin API, creates a temporary API key
// for the tenant, exercises the SDK, and cleans up everything it made (users, order, group, the key). Nothing
// secret lives in this file; pass it in the environment:
//
//   CALLIO_ADMIN_PASS=… [CALLIO_ADMIN_USER=admin] [CALLIO_URL=http://localhost:8080] [CALLIO_TENANT=lab] \
//     dotnet test --filter Category=Integration
//
// CALLIO_IT_AUDIO=1 also downloads one recording (that read is written to the recording's access trail).
// Skipped when CALLIO_ADMIN_PASS is not set.
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Xunit;
using Xunit.Abstractions;
using Xunit.Sdk;

namespace Clarigoinfotech.Callio.Server.Tests;

/// <summary>A Fact that is skipped when CALLIO_ADMIN_PASS is not set.</summary>
public sealed class IntegrationFactAttribute : FactAttribute
{
    public IntegrationFactAttribute()
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CALLIO_ADMIN_PASS")))
            Skip = "set CALLIO_ADMIN_PASS (and optionally CALLIO_ADMIN_USER, CALLIO_URL, CALLIO_TENANT)";
    }
}

[AttributeUsage(AttributeTargets.Method)]
public sealed class StepAttribute(int order) : Attribute
{
    public int Order { get; } = order;
}

/// <summary>Runs the integration steps in [Step] order.</summary>
public sealed class StepOrderer : ITestCaseOrderer
{
    public IEnumerable<TTestCase> OrderTestCases<TTestCase>(IEnumerable<TTestCase> testCases) where TTestCase : ITestCase =>
        testCases.OrderBy(tc => tc.TestMethod.Method.GetCustomAttributes(typeof(StepAttribute).AssemblyQualifiedName!).FirstOrDefault()?.GetNamedArgument<int>("Order") ?? 0);
}

public sealed class IntegrationFixture : IAsyncLifetime
{
    public static readonly string Url = (Env("CALLIO_URL") ?? "http://localhost:8080").TrimEnd('/');
    public static readonly string Tenant = Env("CALLIO_TENANT") ?? "lab";
    public readonly string Run = Convert.ToString(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), 16);
    public string Cust => $"sdk-it-dotnet-c-{Run}";
    public string Agent => $"sdk-it-dotnet-a-{Run}";
    public string OrderId => $"SDK-IT-DOTNET-{Run}";
    public string GroupId => $"sdk-it-dotnet-g-{Run}";

    public CallioClient Callio { get; private set; } = null!;
    public readonly List<string> Users = new();
    public bool GroupMade, OrderMade;

    private readonly HttpClient _admin = new() { Timeout = TimeSpan.FromSeconds(15) };
    private string? _keyId;

    private static string? Env(string k) => Environment.GetEnvironmentVariable(k) is { Length: > 0 } v ? v : null;

    private async Task<JsonElement> AdminReq(HttpMethod m, string path, object? body = null)
    {
        using var req = new HttpRequestMessage(m, Url + path);
        if (body is not null) req.Content = JsonContent.Create(body);
        using var res = await _admin.SendAsync(req);
        var text = await res.Content.ReadAsStringAsync();
        var j = text.Length > 0 ? JsonDocument.Parse(text).RootElement.Clone() : default;
        if (!res.IsSuccessStatusCode) throw new InvalidOperationException($"{m} {path} → {(int)res.StatusCode} {text}");
        return j;
    }

    public async Task InitializeAsync()
    {
        var pass = Env("CALLIO_ADMIN_PASS");
        if (pass is null) return;
        var token = (await AdminReq(HttpMethod.Post, "/api/admin/login", new { username = Env("CALLIO_ADMIN_USER") ?? "admin", password = pass })).GetProperty("token").GetString()
            ?? throw new InvalidOperationException("admin login (MFA-enabled admins are not supported by this test)");
        _admin.DefaultRequestHeaders.Authorization = new("Bearer", token);
        var key = (await AdminReq(HttpMethod.Post, $"/api/admin/tenants/{Tenant}/api-keys", new { name = $"sdk-it-dotnet-{Run}" })).GetProperty("key");
        _keyId = key.GetProperty("id").GetString();
        Callio = new CallioClient(new CallioOptions { ApiKey = key.GetProperty("key").GetString(), BaseUrl = Url, AllowInsecure = Url.StartsWith("http://"), UserAgent = "callio-it" });
    }

    public async Task DisposeAsync()
    {
        if (_keyId is null) return;
        async Task Quiet(Func<Task> f) { try { await f(); } catch { /* best effort */ } }
        try
        {
            if (GroupMade) await Quiet(() => Callio.Groups.DeleteAsync(GroupId));
            if (OrderMade) await Quiet(() => Callio.Orders.CloseAsync(OrderId)); // orders can't be deleted; erasing the users pseudonymises it
            foreach (var u in Users) await Quiet(() => Callio.Users.DeleteAsync(u, "SDK integration test cleanup"));
        }
        finally
        {
            await AdminReq(HttpMethod.Delete, $"/api/admin/tenants/{Tenant}/api-keys/{_keyId}");
        }
        try
        {
            await Callio.Users.ListAsync(new ListUsersParams { Limit = 1 });
            throw new InvalidOperationException("the revoked key still works");
        }
        catch (AuthenticationException)
        {
            // expected
        }
        Callio.Dispose();
        _admin.Dispose();
    }
}

[Trait("Category", "Integration")]
[TestCaseOrderer("Clarigoinfotech.Callio.Server.Tests.StepOrderer", "Clarigoinfotech.Callio.Server.Tests")]
public sealed class IntegrationTests(IntegrationFixture f) : IClassFixture<IntegrationFixture>
{
    private CallioClient C => f.Callio;

    [IntegrationFact, Step(1)]
    public async Task Users()
    {
        var c = await C.Users.CreateAsync(new CreateUserParams { Username = f.Cust, DisplayName = "SDK IT Customer", UserType = UserType.Customer });
        f.Users.Add(f.Cust);
        Assert.Equal(f.Cust, c.Username);
        Assert.Equal("customer", c.UserType);
        Assert.NotEmpty(c.Extension);
        Assert.False(string.IsNullOrEmpty(c.InitialPassword), "a random password is returned once");
        await Assert.ThrowsAsync<ConflictException>(() => C.Users.CreateAsync(new CreateUserParams { Username = f.Cust }));
        await Assert.ThrowsAsync<ValidationException>(() => C.Users.CreateAsync(new CreateUserParams { Username = "bad name!" }));
        await Assert.ThrowsAsync<NotFoundException>(() => C.Users.GetAsync(f.Cust + "-missing"));

        Assert.Equal("SDK IT Customer", (await C.Users.GetAsync(f.Cust)).DisplayName);
        var u = await C.Users.UpdateAsync(f.Cust, new UpdateUserParams { DisplayName = "SDK IT Renamed", Segment = "sdk-it" });
        Assert.Equal("SDK IT Renamed", u.DisplayName);
        Assert.Equal("sdk-it", u.Segment);
        Assert.Contains(await C.Users.ListAsync(new ListUsersParams { Q = f.Cust }), x => x.Username == f.Cust);

        var t = await C.Tokens.CreateAsync(f.Cust, 120);
        Assert.Equal(3, t.Token.Split('.').Length);
        Assert.Equal("customer", t.UserType);
        Assert.True(DateTimeOffset.Parse(t.ExpiresAt) > DateTimeOffset.UtcNow);
        Assert.True((await C.Users.SignOutAsync(f.Cust)).Ok);
        Assert.True((await C.Users.ExportAsync(f.Cust)).TryGetProperty("exportedAt", out _));
    }

    [IntegrationFact, Step(2)]
    public async Task ForUser()
    {
        var first = await C.Tokens.ForUserAsync(f.Agent, new ForUserOptions { DisplayName = "SDK IT Agent", UserType = UserType.Agent, TtlSec = 60 });
        f.Users.Add(f.Agent);
        Assert.True(first.Created);
        Assert.Equal("agent", first.UserType);
        var again = await C.Tokens.ForUserAsync(f.Agent, new ForUserOptions { UserType = UserType.Agent });
        Assert.False(again.Created);
        Assert.NotEmpty(again.Token);
        await C.Users.DisableAsync(f.Agent);
        Assert.Equal(403, (await Assert.ThrowsAnyAsync<CallioException>(() => C.Tokens.CreateAsync(f.Agent))).Status);
        await C.Users.EnableAsync(f.Agent);
    }

    [IntegrationFact, Step(3)]
    public async Task OrdersAndEvents()
    {
        var before = (await C.Events.ListAsync(new ListEventsParams { After = 0, Limit = 1 })).Next;
        await Assert.ThrowsAsync<ValidationException>(() => C.Orders.CreateAsync(new CreateOrderParams { Id = f.OrderId, Customer = f.Agent })); // wrong user type
        var o = await C.Orders.CreateAsync(new CreateOrderParams { Id = f.OrderId, Customer = f.Cust, Label = "SDK integration test" });
        f.OrderMade = true;
        Assert.Equal("active", o.Status);
        Assert.Null(o.Agent);
        await Assert.ThrowsAsync<ConflictException>(() => C.Orders.CreateAsync(new CreateOrderParams { Id = f.OrderId, Customer = f.Cust }));
        Assert.Equal("SDK integration test", (await C.Orders.GetAsync(f.OrderId)).Label);
        Assert.Contains(await C.Orders.ListAsync(new ListOrdersParams { User = f.Cust }), x => x.Id == f.OrderId);
        Assert.Equal(f.Agent, (await C.Orders.AssignAsync(f.OrderId, f.Agent)).Agent);
        Assert.Equal("closed", (await C.Orders.CloseAsync(f.OrderId)).Status);
        Assert.Equal("active", (await C.Orders.ReopenAsync(f.OrderId)).Status);
        Assert.Equal("closed", (await C.Orders.UpdateAsync(f.OrderId, new UpdateOrderParams { Status = OrderStatus.Closed })).Status);
        await Assert.ThrowsAsync<NotFoundException>(() => C.Orders.GetAsync(f.OrderId + "-nope"));

        var seen = new List<string>();
        await foreach (var e in C.Events.IterateAsync(new ListEventsParams { After = Math.Max(0, before - 1), Types = new[] { "order." }, Limit = 100 }))
            if (e.OrderId == f.OrderId) seen.Add(e.Type);
        foreach (var t in new[] { "order.created", "order.assigned", "order.closed", "order.reopened" }) Assert.Contains(t, seen);
    }

    [IntegrationFact, Step(4)]
    public async Task Groups()
    {
        var g = await C.Groups.CreateAsync(new CreateGroupParams { Id = f.GroupId, Name = "SDK IT group", Members = new[] { f.Cust, f.Agent } });
        f.GroupMade = true;
        Assert.Equal(2, g.Members.Count);
        Assert.Equal("SDK IT group", (await C.Groups.GetAsync(f.GroupId)).Name);
        var u = await C.Groups.UpdateAsync(f.GroupId, new UpdateGroupParams { Name = "SDK IT renamed", Remove = new[] { f.Agent } });
        Assert.Equal("SDK IT renamed", u.Name);
        Assert.Equal(new[] { f.Cust }, u.Members.Select(m => m.Username));
        Assert.Contains(await C.Groups.ListAsync(), x => x.Id == f.GroupId);
        Assert.True((await C.Groups.DeleteAsync(f.GroupId)).Ok);
        f.GroupMade = false;
        await Assert.ThrowsAsync<NotFoundException>(() => C.Groups.GetAsync(f.GroupId));
    }

    [IntegrationFact, Step(5)]
    public async Task RecordingsAndCdr()
    {
        var recs = await C.Recordings.ListAsync(new ListRecordingsParams { Limit = 5 });
        if (recs.Count > 0)
        {
            Assert.Equal(recs[0].Id, (await C.Recordings.GetAsync(recs[0].Id)).Id);
            if (Environment.GetEnvironmentVariable("CALLIO_IT_AUDIO") == "1")
            {
                using var ms = new MemoryStream();
                Assert.Equal(recs[0].Bytes, await C.Recordings.DownloadAsync(recs[0].Id, ms, "SDK integration test"));
                Assert.Equal("OggS", Encoding.ASCII.GetString(ms.ToArray(), 0, 4));
            }
        }
        await Assert.ThrowsAsync<NotFoundException>(() => C.Recordings.GetAsync("no-such-recording"));
        await Assert.ThrowsAsync<NotFoundException>(() => C.Recordings.AudioAsync("no-such-recording", "SDK integration test"));
        var cdr = await C.Cdr.ListAsync(new ListCdrParams { Days = 30 });
        Assert.Equal(30, cdr.Days);
        Assert.NotNull(cdr.Calls);
    }

    [IntegrationFact, Step(6)]
    public async Task Erasure()
    {
        var r = await C.Users.DeleteAsync(f.Agent, "SDK integration test cleanup");
        Assert.True(r.Ok);
        Assert.StartsWith("erased-", r.Alias);
        f.Users.Remove(f.Agent);
        await Assert.ThrowsAsync<NotFoundException>(() => C.Users.GetAsync(f.Agent));
    }
}
