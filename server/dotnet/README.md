# Clarigoinfotech.Callio.Server (.NET)

The Callio **server SDK for .NET**: what your backend uses to call Callio's tenant API. It creates and
manages app users, issues the short-lived tokens your mobile app signs in with, links customers and agents
through orders, fetches recordings and transcripts, follows the event feed and call records, and verifies
the webhooks Callio sends you.

- .NET 8, on `System.Net.Http` and `System.Text.Json`. No dependencies beyond the BCL.
- `async`/`await` with `CancellationToken` everywhere; `IAsyncEnumerable` for the event feed.
- Typed exceptions.
- Retries with backoff where they are safe.
- Streamed recording downloads.
- Thread-safe: register one `CallioClient` as a singleton.

The API itself is described in [docs/TENANT_API.md](../../../docs/TENANT_API.md) and as OpenAPI at
`https://<your-callio-host>/api/v1/openapi.json`. Behaviour matches the [Node.js](../node/README.md) and
[Python](../python/README.md) server SDKs.

## Install

NuGet id: `Clarigoinfotech.Callio.Server`. It is not on nuget.org yet; pack it from a checkout and add the
folder as a local source:

```sh
cd sdk/server/dotnet && dotnet pack src/Clarigoinfotech.Callio.Server -c Release -o ./nupkg
dotnet nuget add source /path/to/ngx-p2p/sdk/server/dotnet/nupkg --name callio-local
dotnet add package Clarigoinfotech.Callio.Server --version 0.1.0
```

Or reference the project directly: `dotnet add reference /path/to/sdk/server/dotnet/src/Clarigoinfotech.Callio.Server`.

## Quick start: give your app a token

Create an API key in the Callio admin console (your organisation → **API keys**). Keep it in your server's
secret store.

```csharp
using Clarigoinfotech.Callio.Server;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton(new CallioClient(new CallioOptions
{
    ApiKey = builder.Configuration["Callio:ApiKey"],   // cio_<id>_<secret>
    BaseUrl = "https://api.example.sa",               // your Callio host
}));
var app = builder.Build();

// Your app asks your backend for a Callio token after the user signs in to *your* system.
app.MapPost("/callio-token", async (ClaimsPrincipal user, CallioClient callio, CancellationToken ct) =>
{
    var t = await callio.Tokens.ForUserAsync($"cust-{user.FindFirstValue(ClaimTypes.NameIdentifier)}", new ForUserOptions
    {
        DisplayName = user.Identity?.Name,
        UserType = UserType.Customer,   // or UserType.Agent for drivers, support staff…
        TtlSec = 900,
    }, ct);
    return Results.Ok(new { token = t.Token, expiresAt = t.ExpiresAt });   // the mobile SDK's tokenProvider returns this token
}).RequireAuthorization();
```

`Tokens.ForUserAsync` creates the Callio user the first time it sees them; a `409 user exists` from the
API means they already exist. Then it issues a token (`t.Created` says which). An existing user's name and
type are not changed; use `Users.UpdateAsync` for that. `new CallioClient()` with no options reads
`CALLIO_API_KEY` and `CALLIO_BASE_URL`.

## Options (`CallioOptions`)

| Property | Default | |
|---|---|---|
| `ApiKey` | `CALLIO_API_KEY` | Required |
| `BaseUrl` | `CALLIO_BASE_URL` | Required, `https://…` |
| `AllowInsecure` | `false` | Permit `http://` (a local stack only) |
| `Timeout` | 30 s | Per attempt |
| `MaxRetries` | 2 | Retries for idempotent requests |
| `HttpMessageHandler` | `SocketsHttpHandler` | Proxies, tests, instrumentation. The SDK turns its auto-redirect off and does not dispose it |
| `UserAgent` | | Appended to `User-Agent: callio-server-dotnet/<version> dotnet/<version>` |

## Resources

Models are records; fields the platform adds later land in `Extra`. On the `Update*Params` classes only the
properties you set are sent, and a property set to `null` is sent as JSON null.

### Users

```csharp
var u = await callio.Users.CreateAsync(new CreateUserParams { Username = "cust-42", DisplayName = "Sara", UserType = UserType.Customer });
u.Extension;          // SIP extension
u.InitialPassword;    // only when no LoginPassword was given, returned once

await callio.Users.GetAsync("cust-42");
await callio.Users.ListAsync(new ListUsersParams { Q = "sara", Type = UserType.Customer, Status = "active" });
await callio.Users.UpdateAsync("cust-42", new UpdateUserParams { DisplayName = "Sara A.", Segment = "vip" });
await callio.Users.UpdateAsync("cust-42", new UpdateUserParams { Phone = null });   // clear
await callio.Users.DisableAsync("cust-42");   // ends their sessions; EnableAsync reverses it
await callio.Users.SignOutAsync("cust-42");   // end every open session

// Data-subject requests (PDPL)
JsonElement data = await callio.Users.ExportAsync("cust-42");
await callio.Users.DeleteAsync("cust-42", "customer request #881");   // irreversible erasure
```

### Tokens

```csharp
var t = await callio.Tokens.CreateAsync("cust-42", ttlSec: 600);                                                       // 60–3600 s
var ut = await callio.Tokens.ForUserAsync("drv-7", new ForUserOptions { DisplayName = "Omar", UserType = UserType.Agent }); // ut.Created
```

### Orders

```csharp
await callio.Orders.CreateAsync(new CreateOrderParams { Id = "ORD-1001", Customer = "cust-42", Label = "Grocery delivery" });
await callio.Orders.AssignAsync("ORD-1001", "drv-7");   // the next call goes to drv-7
await callio.Orders.AssignAsync("ORD-1001", null);      // unassign
await callio.Orders.CloseAsync("ORD-1001");             // with "only during an active order", calls stop
await callio.Orders.ReopenAsync("ORD-1001");
await callio.Orders.UpdateAsync("ORD-1001", new UpdateOrderParams { Label = "Pharmacy" });
await callio.Orders.GetAsync("ORD-1001");
await callio.Orders.ListAsync(new ListOrdersParams { Status = OrderStatus.Active, User = "cust-42" });
```

### Recordings

Every audio or transcript fetch needs a **reason** of at least 5 characters, and is written to the
recording's access trail.

```csharp
var recs = await callio.Recordings.ListAsync(new ListRecordingsParams { From = DateTimeOffset.UtcNow.AddDays(-7), OrderId = "ORD-1001", MinDuration = 10 });
var meta = await callio.Recordings.GetAsync(recs[0].Id);

// Stream to a file (never buffered whole in memory)
long bytes = await callio.Recordings.DownloadAsync(meta.Id, "call.ogg", "dispute #4411");

// Or take the stream yourself, e.g. to proxy it from a minimal API
app.MapGet("/recordings/{id}", async (string id, CallioClient callio, HttpResponse res, CancellationToken ct) =>
{
    await using var a = await callio.Recordings.AudioAsync(id, "QA review", ct);
    res.ContentType = a.ContentType;   // audio/ogg: stereo Opus, caller on the left
    await a.Body.CopyToAsync(res.Body, ct);
});

var tr = await callio.Recordings.TranscriptAsync(meta.Id, "QA review");   // NotFoundException until it is ready
```

A deleted recording throws `GoneException` (410). `DownloadAsync(id, Stream, reason)` writes to any stream.

### Groups (group chats)

```csharp
await callio.Groups.CreateAsync(new CreateGroupParams { Id = "ORD-1001", Name = "Order 1001", Members = new[] { "cust-42", "drv-7", "support-1" } });
await callio.Groups.UpdateAsync("ORD-1001", new UpdateGroupParams { Add = new[] { "drv-9" }, Remove = new[] { "drv-7" }, Name = "Order 1001 (reassigned)" });
await callio.Groups.GetAsync("ORD-1001");
await callio.Groups.ListAsync();
await callio.Groups.DeleteAsync("ORD-1001");   // and its messages
```

Groups have 2–50 members. A member added later sees messages from when they joined.

### Events (BI feed) and call records

```csharp
// One page at a time
var page = await callio.Events.ListAsync(new ListEventsParams { After = lastSeenId, Types = new[] { "call.", "order." }, Limit = 1000 });

// Or every event until caught up; store the last id and resume from it next time
await foreach (var e in callio.Events.IterateAsync(new ListEventsParams { After = lastSeenId, Types = new[] { "call." } }, ct))
{
    await warehouse.InsertAsync(e);
    lastSeenId = e.Id;
}

var cdr = await callio.Cdr.ListAsync(new ListCdrParams { Days = 7, Type = UserType.Customer });   // one row per call
```

### Anything else

`callio.Http.RequestAsync<T>(method, path, query, body, ct)` (or `RequestJsonAsync`, `RequestRawAsync`)
calls any endpoint with the same auth, retries and errors.

## Errors

Every failure from the API is a `CallioException` with `Status` (0 when no response arrived), `Message`
(the server's `error` text), `Body` and `Request` (`"GET /api/v1/orders/X"`). Catch the subclass:

| Class | Status | When |
|---|---|---|
| `ValidationException` | 400 | Bad input: id or username format, unknown user, wrong user type, missing reason |
| `AuthenticationException` | 401 | Missing, wrong or revoked key |
| `PermissionDeniedException` | 403 | Organisation suspended, seat quota reached, user disabled (tokens), or *"this network (x) is not allowed to use this organisation's API"* |
| `NotFoundException` | 404 | No such user, order, group or recording; no transcript yet |
| `ConflictException` | 409 | The user or order id already exists |
| `GoneException` | 410 | The recording was deleted |
| `RateLimitException` | 429 | Over the organisation's request rate; `RetryAfter` from `Retry-After` |
| `ServerException` | 5xx | Platform error |
| `RedirectException` | 3xx | The server redirected; never followed (see Security) |
| `ConnectionException` / `CallioTimeoutException` | 0 | No response, or none within `Timeout` |

Arguments are checked before any request: an empty, `.` or `..` id, or a reason under 5 characters, throws
`ArgumentException`. Cancelling your `CancellationToken` throws `OperationCanceledException` (not a
timeout).

```csharp
try
{
    await callio.Orders.CreateAsync(new CreateOrderParams { Id = id, Customer = customer });
}
catch (ConflictException) { /* already pushed */ }
catch (RateLimitException e) { await Task.Delay(e.RetryAfter ?? TimeSpan.FromSeconds(1)); /* retry */ }
```

**Retries.** `GET`, `HEAD`, `PUT`, `DELETE` and `OPTIONS` requests are retried up to `MaxRetries` times on
429, 5xx and network errors. The SDK waits `Retry-After` when the server sends it (capped at 60 s),
otherwise uses exponential backoff with jitter. `POST` and `PATCH` (create user, create order, issue token,
reassign…) are never retried automatically, so a request is never applied twice.

## Webhooks

Callio POSTs each event as JSON to your organisation's webhook URL and signs it with your webhook secret:

```
X-Callio-Timestamp: <unix seconds>
X-Callio-Signature: v1=<hex HMAC-SHA256(secret, timestamp + "." + rawBody)>
X-NGX-Signature:    sha256=<hex HMAC-SHA256(secret, rawBody)>      (legacy)
```

`Webhooks.ParseRequest` checks the `v1` signature in constant time, and rejects a timestamp more than 5
minutes from now (`WebhookOptions.Tolerance`), so a captured request can't be replayed later. Verify the
**raw body** you received, before parsing it. Each event has a unique `Id`: store the ones you have
handled and drop repeats.

```csharp
// ASP.NET Core minimal API
app.MapPost("/callio/webhook", async (HttpRequest req, ILogger<Program> log) =>
{
    using var ms = new MemoryStream();
    await req.Body.CopyToAsync(ms);
    WebhookEvent ev;
    try
    {
        ev = Webhooks.ParseRequest(ms.ToArray(), name => req.Headers[name], app.Configuration["Callio:WebhookSecret"]!);
    }
    catch (WebhookVerificationException)
    {
        return Results.Unauthorized();
    }
    if (AlreadyHandled(ev.Id)) return Results.NoContent();
    switch (ev.Type)
    {
        case "order.assigned": log.LogInformation("{Order} → {Agent} by {By}", ev.Order!.Id, ev.Order.Agent, ev.By); break;
        case "recording.ready": QueueFetch(ev.RecordingId!); break;   // metadata only, never audio
        default: break;                                               // new types may be added
    }
    return Results.NoContent();
});
```

Headers can also be passed as a `Dictionary<string, string>` or `HttpHeaders`-style pairs (any case). A
request without `X-Callio-Timestamp` is rejected. While some senders still use only the legacy header, pass
`new WebhookOptions { AllowLegacy = true }` to fall back to `X-NGX-Signature` (body only, so such a request
could be a replay). `Webhooks.VerifyRequest` only checks. The older
`Webhooks.Verify(body, signatureHeader, secret)` / `Parse` still work but are `[Obsolete]`: they check only
the legacy signature.

Event types include `order.created`, `order.assigned`, `order.closed`, `order.reopened` (with `Order` and
`By`); `call.*` and `chat.*`; `recording.ready`; `cc.chat-escalated`; `report.snapshot`. `ev.Raw` holds the
whole body. Ignore types you don't handle. Delivery is best-effort with no retries today, so use
`Events.IterateAsync` to catch up after downtime.

## Security

- **Keep the key on your server.** It can read every user, order and recording of your organisation. Never
  put it in a mobile app, a web page or a repository. The app gets a short-lived token from your backend
  instead (`Tokens.ForUserAsync`).
- **Restrict where the key works.** In the console, *Server API access* (`apiIpAllowlist`) limits your
  organisation's keys to your servers' networks. Calls from other networks get `403`.
- **Rotate keys.** Create the new key, deploy it, then revoke the old one in the console. A revoked key gets
  `401` immediately.
- **The SDK never logs the key.** It is sent only in the `Authorization` header, never in URLs or
  exceptions; `ToString()` of the client, its options and its HTTP layer leave it out, and the debugger
  doesn't show it. Recording reasons are sent as a query parameter, so don't put personal data in them.
- **Redirects are never followed** (`AllowAutoRedirect = false`, also on a handler you pass). A 3xx throws
  `RedirectException`, so the key can't be carried to another host.
- **HTTPS only.** `http://` is refused unless you set `AllowInsecure = true`, meant for a local stack.
- **Ids are checked.** An empty, `.` or `..` id or username is rejected before any request is built.

## Development

```sh
dotnet test tests/Clarigoinfotech.Callio.Server.Tests                                  # unit tests (scripted handler + a loopback server); integration skipped
CALLIO_ADMIN_PASS=… dotnet test tests/Clarigoinfotech.Callio.Server.Tests --filter Category=Integration
dotnet pack src/Clarigoinfotech.Callio.Server -c Release -o ./nupkg
```

No SDK? Use Docker: `docker run --rm -v "$PWD":/src -w /src mcr.microsoft.com/dotnet/sdk:8.0 dotnet test tests/Clarigoinfotech.Callio.Server.Tests`
(for the integration tests add `-e CALLIO_ADMIN_PASS=… -e CALLIO_URL=http://host.docker.internal:8080`).

The integration test signs in to the admin API (`CALLIO_URL`, default `http://localhost:8080`;
`CALLIO_ADMIN_USER`, default `admin`). It creates a temporary API key for `CALLIO_TENANT` (default `lab`),
runs every resource, and then deletes what it created and revokes the key. Set `CALLIO_IT_AUDIO=1` to also
download one recording.

Versioning: the package starts at 0.1.0 (`CallioClient.Version`) and follows the tenant API (`/api/v1`),
independently of the mobile SDKs.
