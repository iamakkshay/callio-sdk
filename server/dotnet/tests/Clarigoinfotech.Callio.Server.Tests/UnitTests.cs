using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

namespace Clarigoinfotech.Callio.Server.Tests;

/// <summary>A scripted handler: each request takes the next responder.</summary>
internal sealed class MockHandler : HttpMessageHandler
{
    public readonly Queue<Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>>> Responses = new();
    public readonly List<(HttpRequestMessage Req, string? Body)> Calls = new();

    public MockHandler(params Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>>[] rs)
    {
        foreach (var r in rs) Responses.Enqueue(r);
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(ct);
        Calls.Add((request, body));
        if (Responses.Count == 0) throw new InvalidOperationException("unexpected request " + request.RequestUri);
        return await Responses.Dequeue()(request, ct);
    }

    public JsonNode? Json(int i) => Calls[i].Body is { } b ? JsonNode.Parse(b) : null;
    public string Url(int i) => Calls[i].Req.RequestUri!.AbsoluteUri;
    public string? Query(int i, string name)
    {
        foreach (var kv in Calls[i].Req.RequestUri!.Query.TrimStart('?').Split('&'))
        {
            var p = kv.Split('=', 2);
            if (p[0] == name) return WebUtility.UrlDecode(p[1]);
        }
        return null;
    }

    public static Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> J(int status, object? body, params (string, string)[] headers) => (_, _) =>
    {
        var res = new HttpResponseMessage((HttpStatusCode)status);
        if (body is not null) res.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        foreach (var (k, v) in headers) res.Headers.TryAddWithoutValidation(k, v);
        return Task.FromResult(res);
    };
}

public class UnitTests
{
    private const string Key = "cio_abc123_s3cret-value";

    private static CallioClient Client(MockHandler m, int maxRetries = 2, TimeSpan? timeout = null)
    {
        var c = new CallioClient(new CallioOptions { ApiKey = Key, BaseUrl = "https://api.example.test/", HttpMessageHandler = m, MaxRetries = maxRetries, Timeout = timeout ?? TimeSpan.FromSeconds(30) });
        c.Http.Delay = (_, _) => Task.CompletedTask;
        return c;
    }

    private static string Canon(JsonNode? n) => n?.ToJsonString() ?? "null";
    private static string Canon(object o) => JsonSerializer.Serialize(o);

    [Fact]
    public async Task SendsBearerJsonAndUserAgent()
    {
        var m = new MockHandler(MockHandler.J(201, new { user = new { username = "u1", extension = "1001" } }));
        var u = await Client(m).Users.CreateAsync(new CreateUserParams { Username = "u1", DisplayName = "U One", UserType = UserType.Customer });
        Assert.Equal("1001", u.Extension);
        var r = m.Calls[0].Req;
        Assert.Equal("https://api.example.test/api/v1/users", r.RequestUri!.AbsoluteUri);
        Assert.Equal(HttpMethod.Post, r.Method);
        Assert.Equal("Bearer " + Key, r.Headers.Authorization!.ToString());
        Assert.Equal("application/json", r.Content!.Headers.ContentType!.MediaType);
        Assert.Matches("^callio-server-dotnet/" + CallioClient.Version.Replace(".", "\\.") + " dotnet/", string.Join(" ", r.Headers.GetValues("User-Agent")));
        Assert.Equal(Canon(new { username = "u1", displayName = "U One", userType = "customer" }), Canon(m.Json(0)));
    }

    [Fact]
    public async Task QueryAndPathEncoding()
    {
        var m = new MockHandler(MockHandler.J(200, new { users = Array.Empty<object>() }), MockHandler.J(200, new { events = Array.Empty<object>(), next = 5 }),
            MockHandler.J(200, new { user = new { } }), MockHandler.J(200, new { recordings = Array.Empty<object>() }));
        var c = Client(m);
        await c.Users.ListAsync(new ListUsersParams { Q = "sa ra", Type = "agent", Status = null });
        await c.Events.ListAsync(new ListEventsParams { After = 5, Types = new[] { "call.", "chat." } });
        await c.Users.GetAsync("a/b@c");
        await c.Recordings.ListAsync(new ListRecordingsParams { From = DateTimeOffset.Parse("2026-01-01T00:00:00Z"), MinDuration = 10 });
        Assert.Equal("https://api.example.test/api/v1/users?q=sa+ra&type=agent", m.Url(0));
        Assert.Equal("https://api.example.test/api/v1/events?after=5&types=call.%2Cchat.", m.Url(1));
        Assert.Equal("https://api.example.test/api/v1/users/a%2Fb%40c", m.Url(2));
        Assert.Equal("https://api.example.test/api/v1/recordings?from=2026-01-01T00%3A00%3A00.000Z&minDuration=10", m.Url(3));
    }

    [Theory]
    [InlineData(400, typeof(ValidationException))]
    [InlineData(401, typeof(AuthenticationException))]
    [InlineData(403, typeof(PermissionDeniedException))]
    [InlineData(404, typeof(NotFoundException))]
    [InlineData(409, typeof(ConflictException))]
    [InlineData(410, typeof(GoneException))]
    [InlineData(500, typeof(ServerException))]
    [InlineData(418, typeof(CallioException))]
    public async Task StatusesMapToTypedExceptions(int status, Type cls)
    {
        var m = new MockHandler(MockHandler.J(status, new { error = $"reason {status}" }));
        var e = await Assert.ThrowsAnyAsync<CallioException>(() => Client(m, 0).Orders.GetAsync("X"));
        Assert.Equal(cls, e.GetType());
        Assert.Equal(status, e.Status);
        Assert.Equal($"reason {status}", e.Message);
        Assert.Equal("GET /api/v1/orders/X", e.Request);
        Assert.DoesNotContain(Key, e.ToString());
    }

    [Fact]
    public async Task IpAllowList403()
    {
        var m = new MockHandler(MockHandler.J(403, new { error = "this network (203.0.113.9) is not allowed to use this organisation's API" }));
        var e = await Assert.ThrowsAsync<PermissionDeniedException>(() => Client(m).Users.ListAsync());
        Assert.Contains("not allowed", e.Message);
    }

    [Fact]
    public async Task GetRetriesHonouringRetryAfter()
    {
        var m = new MockHandler(MockHandler.J(429, new { error = "slow down" }, ("Retry-After", "2")), MockHandler.J(503, new { error = "busy" }), MockHandler.J(200, new { orders = new[] { new { id = "A" } } }));
        var c = Client(m);
        var waits = new List<string>();
        c.Http.Backoff = (a, ra) => { waits.Add($"{a}:{ra?.TotalSeconds.ToString() ?? "null"}"); return TimeSpan.Zero; };
        var orders = await c.Orders.ListAsync();
        Assert.Equal("A", orders[0].Id);
        Assert.Equal(3, m.Calls.Count);
        Assert.Equal(new[] { "0:2", "1:null" }, waits);
    }

    [Fact]
    public async Task GivesUpWithRateLimitRetryAfter()
    {
        var m = new MockHandler(MockHandler.J(429, new { error = "a" }, ("Retry-After", "7")), MockHandler.J(429, new { error = "b" }, ("Retry-After", "7")));
        var e = await Assert.ThrowsAsync<RateLimitException>(() => Client(m, 1).Cdr.ListAsync());
        Assert.Equal(TimeSpan.FromSeconds(7), e.RetryAfter);
        Assert.Equal(429, e.Status);
        Assert.Equal(2, m.Calls.Count);
    }

    [Fact]
    public async Task PostAndPatchNeverRetried()
    {
        var m1 = new MockHandler(MockHandler.J(503, new { error = "busy" }));
        await Assert.ThrowsAsync<ServerException>(() => Client(m1).Orders.CreateAsync(new CreateOrderParams { Id = "O1", Customer = "c" }));
        Assert.Single(m1.Calls);
        var m2 = new MockHandler(MockHandler.J(429, new { error = "slow" }, ("Retry-After", "1")));
        await Assert.ThrowsAsync<RateLimitException>(() => Client(m2).Orders.CloseAsync("O1"));
        Assert.Single(m2.Calls);
    }

    [Fact]
    public async Task NetworkErrorsRetriedForGet()
    {
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> boom = (_, _) => throw new HttpRequestException("connection refused");
        var m = new MockHandler(boom, boom, boom);
        var e = await Assert.ThrowsAsync<ConnectionException>(() => Client(m).Groups.ListAsync());
        Assert.Equal(0, e.Status);
        Assert.DoesNotContain(Key, e.ToString());
        Assert.Equal(3, m.Calls.Count);
    }

    [Fact]
    public async Task TimesOut()
    {
        var m = new MockHandler(async (_, ct) => { await Task.Delay(Timeout.Infinite, ct); return new HttpResponseMessage(); });
        var e = await Assert.ThrowsAsync<CallioTimeoutException>(() => Client(m, 0, TimeSpan.FromMilliseconds(50)).Users.GetAsync("x"));
        Assert.IsAssignableFrom<ConnectionException>(e);
    }

    [Fact]
    public async Task CallerCancellationIsNotATimeout()
    {
        var m = new MockHandler(async (_, ct) => { await Task.Delay(Timeout.Infinite, ct); return new HttpResponseMessage(); });
        using var cts = new CancellationTokenSource(50);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Client(m).Users.GetAsync("x", cts.Token));
        Assert.Single(m.Calls);
    }

    [Fact]
    public async Task ForUserCreatesThenIssues()
    {
        var m = new MockHandler(MockHandler.J(201, new { user = new { username = "c1" } }), MockHandler.J(200, new { token = "jwt", userType = "customer", expiresAt = "later" }));
        var t = await Client(m).Tokens.ForUserAsync("c1", new ForUserOptions { DisplayName = "C", UserType = UserType.Customer, TtlSec = 600 });
        Assert.Equal(("jwt", "customer", "later", true), (t.Token, t.UserType, t.ExpiresAt, t.Created));
        Assert.Equal(Canon(new { username = "c1", displayName = "C", userType = "customer" }), Canon(m.Json(0)));
        Assert.Equal(Canon(new { username = "c1", ttlSec = 600 }), Canon(m.Json(1)));
    }

    [Fact]
    public async Task ForUser409MeansExists()
    {
        var m = new MockHandler(MockHandler.J(409, new { error = "user exists" }), MockHandler.J(200, new { token = "jwt", userType = "agent", expiresAt = "x" }));
        var t = await Client(m).Tokens.ForUserAsync("a1", new ForUserOptions { UserType = UserType.Agent });
        Assert.False(t.Created);
        Assert.Equal("jwt", t.Token);
    }

    [Fact]
    public async Task ForUserPropagatesOtherErrors()
    {
        var m = new MockHandler(MockHandler.J(403, new { error = "seat quota reached" }));
        await Assert.ThrowsAsync<PermissionDeniedException>(() => Client(m).Tokens.ForUserAsync("a1"));
        Assert.Single(m.Calls);
    }

    [Fact]
    public async Task OrderHelpersPatch()
    {
        var o = new { order = new { id = "O1" } };
        var m = new MockHandler(MockHandler.J(200, o), MockHandler.J(200, o), MockHandler.J(200, o), MockHandler.J(200, o));
        var c = Client(m);
        await c.Orders.AssignAsync("O1", "drv");
        await c.Orders.AssignAsync("O1", null);
        await c.Orders.CloseAsync("O1");
        await c.Orders.ReopenAsync("O1");
        Assert.All(m.Calls, x => Assert.Equal(HttpMethod.Patch, x.Req.Method));
        Assert.Equal(new[] { "{\"agent\":\"drv\"}", "{\"agent\":null}", "{\"status\":\"closed\"}", "{\"status\":\"active\"}" }, m.Calls.Select(x => x.Body));
    }

    [Fact]
    public async Task UsersDisableEnableAndNullableFields()
    {
        var u = new { user = new { username = "u1" } };
        var m = new MockHandler(MockHandler.J(200, u), MockHandler.J(200, u), MockHandler.J(200, u));
        var c = Client(m);
        await c.Users.DisableAsync("u1");
        await c.Users.EnableAsync("u1");
        await c.Users.UpdateAsync("u1", new UpdateUserParams { DisplayName = "N", Segment = null });
        Assert.Equal(new[] { "{\"disabled\":true}", "{\"disabled\":false}", "{\"displayName\":\"N\",\"segment\":null}" }, m.Calls.Select(x => x.Body));
    }

    [Fact]
    public async Task UsersDeleteSendsReason()
    {
        var m = new MockHandler(MockHandler.J(200, new { ok = true, alias = "erased-1", removed = new { }, recordingsKeptOnLegalHold = Array.Empty<string>() }));
        var r = await Client(m).Users.DeleteAsync("u1", "customer asked");
        Assert.Equal("erased-1", r.Alias);
        Assert.Equal(HttpMethod.Delete, m.Calls[0].Req.Method);
        Assert.Equal("{\"reason\":\"customer asked\"}", m.Calls[0].Body);
    }

    [Fact]
    public async Task RecordingAudioStreamsAndDownloads()
    {
        var bytes = new byte[] { 79, 103, 103, 83, 1, 2, 3 };
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> audio = (_, _) =>
        {
            var res = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) };
            res.Content.Headers.ContentType = new("audio/ogg");
            res.Content.Headers.ContentLength = bytes.Length;
            return Task.FromResult(res);
        };
        var m = new MockHandler(audio, audio, audio);
        var c = Client(m);
        await using (var a = await c.Recordings.AudioAsync("rec-1", "QA review — طلب"))
        {
            Assert.Equal("audio/ogg", a.ContentType);
            Assert.Equal(7, a.ContentLength);
            using var ms = new MemoryStream();
            await a.Body.CopyToAsync(ms);
            Assert.Equal(bytes, ms.ToArray());
        }
        Assert.Equal("QA review — طلب", m.Query(0, "reason"));
        Assert.Equal("*/*", m.Calls[0].Req.Headers.Accept.ToString());
        var file = Path.Combine(Path.GetTempPath(), "callio-" + Guid.NewGuid() + ".ogg");
        Assert.Equal(7, await c.Recordings.DownloadAsync("rec-1", file, "dispute 123"));
        Assert.Equal(bytes, await File.ReadAllBytesAsync(file));
        File.Delete(file);
        using var dest = new MemoryStream();
        Assert.Equal(7, await c.Recordings.DownloadAsync("rec-1", dest, "dispute 123"));
        Assert.Equal(bytes, dest.ToArray());
    }

    [Fact]
    public async Task RecordingAudioRequiresReasonAndMaps410()
    {
        var m = new MockHandler(MockHandler.J(410, new { error = "this recording was deleted" }));
        var c = Client(m);
        await Assert.ThrowsAsync<ArgumentException>(() => c.Recordings.AudioAsync("r", "no"));
        await Assert.ThrowsAsync<ArgumentException>(() => c.Recordings.TranscriptAsync("r", "    "));
        await Assert.ThrowsAsync<GoneException>(() => c.Recordings.AudioAsync("r", "audit check"));
        Assert.Single(m.Calls);
    }

    [Theory]
    [InlineData("")]
    [InlineData(".")]
    [InlineData("..")]
    public async Task RejectsDotPathSegments(string id)
    {
        var m = new MockHandler();
        var c = Client(m);
        await Assert.ThrowsAsync<ArgumentException>(() => c.Users.GetAsync(id));
        await Assert.ThrowsAsync<ArgumentException>(() => c.Orders.CloseAsync(id));
        await Assert.ThrowsAsync<ArgumentException>(() => c.Groups.DeleteAsync(id));
        Assert.Empty(m.Calls);
    }

    [Fact]
    public async Task TranscriptRead()
    {
        var m = new MockHandler(MockHandler.J(200, new { transcript = new { text = "hello", language = "en", segments = new[] { new { start = 0, end = 1.5, text = "hello" } } } }));
        var t = await Client(m).Recordings.TranscriptAsync("r1", "QA review");
        Assert.Equal("hello", t.Text);
        Assert.Equal(1.5, t.Segments![0].End);
        Assert.Equal("QA review", m.Query(0, "reason"));
    }

    [Fact]
    public async Task EventsIteratePagesUntilCaughtUp()
    {
        var m = new MockHandler(MockHandler.J(200, new { events = new[] { new { id = 1 }, new { id = 2 } }, next = 2 }), MockHandler.J(200, new { events = new[] { new { id = 3 } }, next = 3 }), MockHandler.J(200, new { events = Array.Empty<object>(), next = 3 }));
        var ids = new List<long>();
        await foreach (var e in Client(m).Events.IterateAsync(new ListEventsParams { Limit = 2 })) ids.Add(e.Id);
        Assert.Equal(new long[] { 1, 2, 3 }, ids);
        Assert.Equal(new[] { "0", "2", "3" }, new[] { m.Query(0, "after"), m.Query(1, "after"), m.Query(2, "after") });
    }

    [Fact]
    public async Task RawRequestEscapeHatch()
    {
        var m = new MockHandler(MockHandler.J(200, new { hello = "world" }));
        var r = await Client(m).Http.RequestJsonAsync(HttpMethod.Get, "/api/v1/whatever", new[] { new KeyValuePair<string, object?>("x", 1) });
        Assert.Equal("world", r!.Value.GetProperty("hello").GetString());
        Assert.Equal("https://api.example.test/api/v1/whatever?x=1", m.Url(0));
    }

    [Fact]
    public void KeyNeverInToString()
    {
        var c = Client(new MockHandler());
        Assert.DoesNotContain(Key, c.ToString());
        Assert.DoesNotContain(Key, c.Http.ToString());
        Assert.DoesNotContain(Key, new CallioOptions { ApiKey = Key }.ToString());
    }

    [Fact]
    public void OptionsValidateReadEnvAndRequireHttps()
    {
        var saveK = Environment.GetEnvironmentVariable("CALLIO_API_KEY");
        var saveU = Environment.GetEnvironmentVariable("CALLIO_BASE_URL");
        Environment.SetEnvironmentVariable("CALLIO_API_KEY", null);
        Environment.SetEnvironmentVariable("CALLIO_BASE_URL", null);
        try
        {
            Assert.Contains("ApiKey is required", Assert.Throws<CallioException>(() => new CallioClient(new CallioOptions { BaseUrl = "https://x" })).Message);
            Assert.Contains("BaseUrl is required", Assert.Throws<CallioException>(() => new CallioClient(new CallioOptions { ApiKey = Key })).Message);
            Assert.Contains("https", Assert.Throws<CallioException>(() => new CallioClient(new CallioOptions { ApiKey = Key, BaseUrl = "api.example.sa" })).Message);
            Assert.Contains("AllowInsecure", Assert.Throws<CallioException>(() => new CallioClient(new CallioOptions { ApiKey = Key, BaseUrl = "http://localhost:8080" })).Message);
            Assert.Equal("http://localhost:8080", new CallioClient(new CallioOptions { ApiKey = Key, BaseUrl = "http://localhost:8080/", AllowInsecure = true }).Http.BaseUrl);
            Environment.SetEnvironmentVariable("CALLIO_API_KEY", Key);
            Environment.SetEnvironmentVariable("CALLIO_BASE_URL", "https://env.example/");
            Assert.Equal("https://env.example", new CallioClient().Http.BaseUrl);
        }
        finally
        {
            Environment.SetEnvironmentVariable("CALLIO_API_KEY", saveK);
            Environment.SetEnvironmentVariable("CALLIO_BASE_URL", saveU);
        }
    }

    [Fact]
    public async Task RedirectsAreRefused()
    {
        var m = new MockHandler(MockHandler.J(302, null, ("Location", "https://evil.example/steal?x=1")), MockHandler.J(200, new { users = Array.Empty<object>() }));
        var e = await Assert.ThrowsAsync<RedirectException>(() => Client(m).Users.ListAsync());
        Assert.Equal(302, e.Status);
        Assert.Contains("https://evil.example", e.Message);
        Assert.Single(m.Calls);
        // A caller-supplied handler that would follow redirects has them turned off.
        var h = new HttpClientHandler { AllowAutoRedirect = true };
        using var c = new CallioClient(new CallioOptions { ApiKey = Key, BaseUrl = "https://x.example", HttpMessageHandler = h });
        Assert.False(h.AllowAutoRedirect);
    }

    [Fact]
    public async Task RealSocketsHandlerDoesNotFollowRedirectsAndTimesOut()
    {
        var evilHits = 0;
        var evil = new TcpListener(IPAddress.Loopback, 0);
        evil.Start();
        var evilPort = ((IPEndPoint)evil.LocalEndpoint).Port;
        _ = Task.Run(async () => { while (true) { using var s = await evil.AcceptTcpClientAsync(); Interlocked.Increment(ref evilHits); } });
        var srv = new TcpListener(IPAddress.Loopback, 0);
        srv.Start();
        var port = ((IPEndPoint)srv.LocalEndpoint).Port;
        _ = Task.Run(async () =>
        {
            while (true)
            {
                var cl = await srv.AcceptTcpClientAsync();
                _ = Task.Run(async () =>
                {
                    using var _c = cl;
                    var st = cl.GetStream();
                    var buf = new byte[8192];
                    var n = await st.ReadAsync(buf);
                    var req = Encoding.ASCII.GetString(buf, 0, n);
                    string resp;
                    if (req.StartsWith("GET /api/v1/users")) resp = $"HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:{evilPort}/api/v1/users\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                    else if (req.StartsWith("GET /api/v1/groups")) { await Task.Delay(3000); resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"; }
                    else resp = "HTTP/1.1 200 OK\r\nContent-Type: audio/ogg\r\nContent-Length: 11\r\nConnection: close\r\n\r\nOggS-stream";
                    var b = Encoding.ASCII.GetBytes(resp);
                    try { await st.WriteAsync(b); } catch (IOException) { }
                });
            }
        });
        try
        {
            using var c = new CallioClient(new CallioOptions { ApiKey = Key, BaseUrl = $"http://127.0.0.1:{port}", AllowInsecure = true, Timeout = TimeSpan.FromMilliseconds(1000), MaxRetries = 0 });
            await Assert.ThrowsAsync<RedirectException>(() => c.Users.ListAsync());
            Assert.Equal(0, evilHits);
            await Assert.ThrowsAsync<CallioTimeoutException>(() => c.Groups.ListAsync());
            await using var a = await c.Recordings.AudioAsync("r1", "QA review");
            using var ms = new MemoryStream();
            await a.Body.CopyToAsync(ms);
            Assert.Equal("OggS-stream", Encoding.ASCII.GetString(ms.ToArray()));
        }
        finally
        {
            srv.Stop();
            evil.Stop();
        }
    }

    [Fact]
    public void ParseRetryAfter()
    {
        Assert.Equal(TimeSpan.FromSeconds(3), CallioHttp.ParseRetryAfter("3"));
        var s = CallioHttp.ParseRetryAfter(DateTimeOffset.UtcNow.AddSeconds(5).ToString("r"))!.Value.TotalSeconds;
        Assert.InRange(s, 4, 6);
        Assert.Null(CallioHttp.ParseRetryAfter(""));
        Assert.Null(CallioHttp.ParseRetryAfter("soon"));
        Assert.Null(CallioHttp.ParseRetryAfter("-1"));
    }

    // ---------------------------------------------------------------- webhooks

    private const string Secret = "whsec_test";
    private static readonly byte[] Body = Encoding.UTF8.GetBytes("{\"tenantId\":\"lab\",\"type\":\"order.assigned\",\"order\":{\"id\":\"O1\",\"agent\":\"drv\"},\"by\":\"apikey:abc\",\"at\":\"2026-01-01T00:00:00Z\"}");
    private static readonly byte[] BodyV1 = Encoding.UTF8.GetBytes("{\"id\":\"evt_01\",\"tenantId\":\"lab\",\"type\":\"recording.ready\",\"recordingId\":\"rec-9\",\"durationSec\":42,\"at\":\"2026-01-01T00:00:00Z\"}");

    private static string HmacHex(string secret, byte[] data) => Convert.ToHexString(HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), data)).ToLowerInvariant();

    private static Dictionary<string, string> V1Headers(byte[] body, long ts, string secret) => new()
    {
        ["x-callio-timestamp"] = ts.ToString(),
        ["x-callio-signature"] = Webhooks.SignV1(body, ts, secret),
        ["x-ngx-signature"] = Webhooks.Sign(body, secret),
    };

    [Fact]
    public void LegacyVerify()
    {
        var sig = "sha256=" + HmacHex(Secret, Body);
        Assert.Equal(sig, Webhooks.Sign(Body, Secret));
        Assert.True(Webhooks.Verify(Body, sig, Secret));
        Assert.True(Webhooks.Verify(Encoding.UTF8.GetString(Body), "  " + sig + " ", Secret));
        Assert.True(Webhooks.Verify(Body, "sha256=" + sig[7..].ToUpperInvariant(), Secret));
        Assert.False(Webhooks.Verify(Body.Append((byte)' ').ToArray(), sig, Secret));
        Assert.False(Webhooks.Verify(Body, sig, "other"));
        foreach (var h in new[] { null, "", "sha256=", "sha256=zz", sig[7..], "sha1=" + sig[7..], sig + "00" }) Assert.False(Webhooks.Verify(Body, h, Secret), h);
        Assert.Throws<ArgumentException>(() => Webhooks.Verify(Body, sig, ""));
    }

    [Fact]
    public void LegacyParse()
    {
        var ev = Webhooks.Parse(Body, Webhooks.Sign(Body, Secret), Secret);
        Assert.True(ev.IsOrderEvent);
        Assert.Equal("drv", ev.Order!.Agent);
        Assert.Equal("apikey:abc", ev.By);
        Assert.Throws<WebhookVerificationException>(() => Webhooks.Parse(Body, "sha256=" + new string('0', 64), Secret));
        var notJson = Encoding.UTF8.GetBytes("nope");
        Assert.Equal(400, Assert.Throws<WebhookVerificationException>(() => Webhooks.Parse(notJson, Webhooks.Sign(notJson, Secret), Secret)).Status);
    }

    [Fact]
    public void VerifyRequestV1()
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var h = V1Headers(BodyV1, now, Secret);
        Assert.Equal("v1=" + HmacHex(Secret, Encoding.UTF8.GetBytes(now + "." + Encoding.UTF8.GetString(BodyV1))), h["x-callio-signature"]);
        Webhooks.VerifyRequest(BodyV1, h, Secret);
        var ev = Webhooks.ParseRequest(BodyV1, h, Secret);
        Assert.Equal("evt_01", ev.Id);
        Assert.True(ev.IsRecordingReady);
        Assert.Equal("rec-9", ev.RecordingId);
        Webhooks.VerifyRequest(BodyV1, name => h.GetValueOrDefault(name.ToLowerInvariant()), Secret);
        var upper = h.ToDictionary(kv => kv.Key.ToUpperInvariant(), kv => (IEnumerable<string>)new[] { kv.Value });
        Webhooks.VerifyRequest(BodyV1, upper, Secret);
        var rot = new Dictionary<string, string>(h) { ["x-callio-signature"] = "v1=" + new string('0', 64) + ", " + h["x-callio-signature"] };
        Webhooks.VerifyRequest(BodyV1, rot, Secret);
    }

    private sealed class FixedClock(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }

    [Fact]
    public void VerifyRequestRejects()
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        Dictionary<string, string> With(Action<Dictionary<string, string>> f) { var h = V1Headers(BodyV1, now, Secret); f(h); return h; }
        var bad = new List<(string, byte[], Dictionary<string, string>, WebhookOptions?)>
        {
            ("tampered", BodyV1.Append((byte)' ').ToArray(), V1Headers(BodyV1, now, Secret), null),
            ("wrong secret", BodyV1, V1Headers(BodyV1, now, "other"), null),
            ("stale (replay)", BodyV1, V1Headers(BodyV1, now - 301, Secret), null),
            ("future", BodyV1, V1Headers(BodyV1, now + 301, Secret), null),
            ("swapped timestamp", BodyV1, With(h => h["x-callio-timestamp"] = (now + 1).ToString()), null),
            ("malformed timestamp", BodyV1, With(h => h["x-callio-timestamp"] = "yesterday"), null),
            ("timestamp without v1", BodyV1, With(h => h.Remove("x-callio-signature")), new WebhookOptions { AllowLegacy = true }),
            ("legacy only, not allowed", BodyV1, With(h => h.Remove("x-callio-timestamp")), null),
            ("custom tolerance", BodyV1, V1Headers(BodyV1, now - 60, Secret), new WebhookOptions { Tolerance = TimeSpan.FromSeconds(30) }),
            ("clock", BodyV1, V1Headers(BodyV1, now, Secret), new WebhookOptions { Clock = new FixedClock(DateTimeOffset.FromUnixTimeSeconds(now + 1000)) }),
        };
        foreach (var (name, body, h, o) in bad)
        {
            var e = Assert.Throws<WebhookVerificationException>(() => Webhooks.VerifyRequest(body, h, Secret, o));
            Assert.True(e.Status == 401, name);
            Assert.Throws<WebhookVerificationException>(() => Webhooks.ParseRequest(body, h, Secret, o));
        }
        Webhooks.VerifyRequest(BodyV1, V1Headers(BodyV1, now - 600, Secret), Secret, new WebhookOptions { Tolerance = TimeSpan.FromMinutes(15) });
        Assert.Throws<ArgumentException>(() => Webhooks.VerifyRequest(BodyV1, V1Headers(BodyV1, now, Secret), ""));
    }

    [Fact]
    public void VerifyRequestAllowLegacy()
    {
        Webhooks.VerifyRequest(BodyV1, new Dictionary<string, string> { ["X-NGX-Signature"] = Webhooks.Sign(BodyV1, Secret) }, Secret, new WebhookOptions { AllowLegacy = true });
        Assert.Throws<WebhookVerificationException>(() => Webhooks.VerifyRequest(BodyV1, new Dictionary<string, string> { ["X-NGX-Signature"] = Webhooks.Sign(BodyV1, "other") }, Secret, new WebhookOptions { AllowLegacy = true }));
    }

    [Fact]
    public void VersionMatchesCsproj()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "src", "Clarigoinfotech.Callio.Server", "Clarigoinfotech.Callio.Server.csproj"))) dir = Path.GetDirectoryName(dir)!;
        var csproj = File.ReadAllText(Path.Combine(dir, "src", "Clarigoinfotech.Callio.Server", "Clarigoinfotech.Callio.Server.csproj"));
        Assert.Contains($"<Version>{CallioClient.Version}</Version>", csproj);
    }
}
