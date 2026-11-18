# Callio server SDK for Java

The Callio **server SDK for Java**: what your backend uses to call Callio's tenant API. It creates and
manages app users, issues the short-lived tokens your mobile app signs in with, links customers and agents
through orders, fetches recordings and transcripts, follows the event feed and call records, and verifies
the webhooks Callio sends you.

- Java 11 or later, on `java.net.http.HttpClient`. **No runtime dependencies** (a small built-in JSON codec).
- Typed, unchecked exceptions.
- Retries with backoff where they are safe.
- Streamed recording downloads.
- Thread-safe: create one client and share it.

The API itself is described in [docs/TENANT_API.md](../../../docs/TENANT_API.md) and as OpenAPI at
`https://<your-callio-host>/api/v1/openapi.json`. Behaviour matches the [Node.js](../node/README.md) and
[Python](../python/README.md) server SDKs.

## Install

Maven coordinates: `com.clarigoinfotech:callio-server:0.1.0`. It is not on Maven Central yet; install it
from a checkout into your local repository:

```sh
cd sdk/server/java && mvn install        # or: docker run --rm -v "$PWD":/src -w /src maven:3-eclipse-temurin-21 mvn install
```

```xml
<dependency>
  <groupId>com.clarigoinfotech</groupId>
  <artifactId>callio-server</artifactId>
  <version>0.1.0</version>
</dependency>
```

Gradle: `implementation("com.clarigoinfotech:callio-server:0.1.0")` with `mavenLocal()`.

## Quick start: give your app a token

Create an API key in the Callio admin console (your organisation → **API keys**). Keep it in your server's
secret store.

```java
import com.clarigoinfotech.callio.*;

Callio callio = Callio.builder()
    .apiKey(System.getenv("CALLIO_API_KEY"))   // cio_<id>_<secret>
    .baseUrl("https://api.example.sa")         // your Callio host
    .build();

// Your app asks your backend for a Callio token after the user signs in to *your* system (Spring Boot):
@PostMapping("/callio-token")
Map<String, String> callioToken(@AuthenticationPrincipal AppUser user) {
  UserToken t = callio.tokens().forUser("cust-" + user.getId(), new ForUserOptions()
      .displayName(user.getName())
      .userType("customer")          // or "agent" for drivers, support staff…
      .ttlSec(900));
  return Map.of("token", t.token(), "expiresAt", t.expiresAt());   // the mobile SDK's tokenProvider returns this token
}
```

`tokens().forUser()` creates the Callio user the first time it sees them; a `409 user exists` from the API
means they already exist. Then it issues a token (`t.created()` says which). An existing user's name and
type are not changed; use `users().update()` for that. `Callio.fromEnv()` reads `CALLIO_API_KEY` and
`CALLIO_BASE_URL`.

## Options

| Builder method | Default | |
|---|---|---|
| `apiKey` | `CALLIO_API_KEY` | Required |
| `baseUrl` | `CALLIO_BASE_URL` | Required, `https://…` |
| `allowInsecure(true)` | off | Permit `http://` (a local stack only) |
| `timeout` | 30 s | Per attempt |
| `maxRetries` | 2 | Retries for idempotent requests |
| `transport` | `JdkTransport` | Replace for proxies, tests or instrumentation; `new JdkTransport(httpClient)` takes your own `HttpClient` (it must use `Redirect.NEVER`) |
| `userAgent` | | Appended to `User-Agent: callio-server-java/<version> java/<version>` |

## Resources

Models (`User`, `Order`, `Recording`…) have typed getters, and `raw()` / `get(field)` for anything else.
Parameter objects are fluent; only the fields you set are sent, and a field set to `null` is sent as JSON
null.

### Users

```java
CreatedUser u = callio.users().create(new CreateUserParams("cust-42").displayName("Sara").userType("customer"));
u.extension();          // SIP extension
u.initialPassword();    // only when no loginPassword was given, returned once

callio.users().get("cust-42");
callio.users().list(new ListUsersParams().q("sara").type("customer").status("active"));
callio.users().update("cust-42", new UpdateUserParams().displayName("Sara A.").segment("vip"));
callio.users().update("cust-42", new UpdateUserParams().phone(null));   // clear
callio.users().disable("cust-42");   // ends their sessions; enable() reverses it
callio.users().signOut("cust-42");   // end every open session

// Data-subject requests (PDPL)
Map<String, Object> data = callio.users().export("cust-42");
callio.users().delete("cust-42", "customer request #881");   // irreversible erasure
```

### Tokens

```java
Token t = callio.tokens().create("cust-42", 600);                                                         // 60–3600 s
UserToken ut = callio.tokens().forUser("drv-7", new ForUserOptions().displayName("Omar").userType("agent")); // ut.created()
```

### Orders

```java
callio.orders().create(new CreateOrderParams("ORD-1001", "cust-42").label("Grocery delivery"));
callio.orders().assign("ORD-1001", "drv-7");   // the next call goes to drv-7
callio.orders().assign("ORD-1001", null);      // unassign
callio.orders().close("ORD-1001");             // with "only during an active order", calls stop
callio.orders().reopen("ORD-1001");
callio.orders().update("ORD-1001", new UpdateOrderParams().label("Pharmacy"));
callio.orders().get("ORD-1001");
callio.orders().list(new ListOrdersParams().status("active").user("cust-42"));
```

### Recordings

Every audio or transcript fetch needs a **reason** of at least 5 characters, and is written to the
recording's access trail.

```java
List<Recording> recs = callio.recordings().list(new ListRecordingsParams().from(LocalDate.of(2026, 11, 1)).orderId("ORD-1001").minDuration(10));
Recording meta = callio.recordings().get(recs.get(0).id());

// Stream to a file (never buffered whole in memory)
long bytes = callio.recordings().download(meta.id(), Path.of("call.ogg"), "dispute #4411");

// Or take the stream yourself, e.g. to proxy it
try (RecordingAudio a = callio.recordings().audio(meta.id(), "QA review")) {
  response.setContentType(a.contentType());   // audio/ogg: stereo Opus, caller on the left
  a.body().transferTo(response.getOutputStream());
}

Transcript tr = callio.recordings().transcript(meta.id(), "QA review");   // NotFoundException until it is ready
```

A deleted recording throws `GoneException` (410). `download(id, OutputStream, reason)` writes to any stream.

### Groups (group chats)

```java
callio.groups().create(new CreateGroupParams("ORD-1001", "Order 1001", List.of("cust-42", "drv-7", "support-1")));
callio.groups().update("ORD-1001", new UpdateGroupParams().add("drv-9").remove("drv-7").name("Order 1001 (reassigned)"));
callio.groups().get("ORD-1001");
callio.groups().list();
callio.groups().delete("ORD-1001");   // and its messages
```

Groups have 2–50 members. A member added later sees messages from when they joined.

### Events (BI feed) and call records

```java
// One page at a time
EventPage page = callio.events().list(new ListEventsParams().after(lastSeenId).types("call.", "order.").limit(1000));

// Or every event until caught up (lazy); store the last id and resume from it next time
for (CallioEvent e : callio.events().iterate(new ListEventsParams().after(lastSeenId).types("call."))) {
  warehouse.insert(e.raw());
  lastSeenId = e.id();
}
// callio.events().stream(params) gives the same as a Stream<CallioEvent>.

CdrPage cdr = callio.cdr().list(new ListCdrParams().days(7).type("customer"));   // one row per call
```

### Anything else

`callio.http().request(method, path, query, body)` (or `requestObject`, `requestRaw`) calls any endpoint
with the same auth, retries and errors.

## Errors

Every failure from the API is a `CallioException` (unchecked) with `status()` (0 when no response arrived),
`getMessage()` (the server's `error` text), `body()` and `request()` (`"GET /api/v1/orders/X"`). Catch the
subclass:

| Class | Status | When |
|---|---|---|
| `ValidationException` | 400 | Bad input: id or username format, unknown user, wrong user type, missing reason |
| `AuthenticationException` | 401 | Missing, wrong or revoked key |
| `PermissionDeniedException` | 403 | Organisation suspended, seat quota reached, user disabled (tokens), or *"this network (x) is not allowed to use this organisation's API"* |
| `NotFoundException` | 404 | No such user, order, group or recording; no transcript yet |
| `ConflictException` | 409 | The user or order id already exists |
| `GoneException` | 410 | The recording was deleted |
| `RateLimitException` | 429 | Over the organisation's request rate; `retryAfter()` from `Retry-After` |
| `ServerException` | 5xx | Platform error |
| `RedirectException` | 3xx | The server redirected; never followed (see Security) |
| `ConnectionException` / `RequestTimeoutException` | 0 | No response, or none within the timeout |

Arguments are checked before any request: an empty, `.` or `..` id, or a reason under 5 characters, throws
`IllegalArgumentException`.

```java
try {
  callio.orders().create(new CreateOrderParams(id, customer));
} catch (ConflictException e) {
  // already pushed
} catch (RateLimitException e) {
  Thread.sleep(e.retryAfter().orElse(Duration.ofSeconds(1)).toMillis());   // then retry
}
```

**Retries.** `GET`, `HEAD`, `PUT`, `DELETE` and `OPTIONS` requests are retried up to `maxRetries` times on
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

`Webhooks.parseRequest` checks the `v1` signature in constant time, and rejects a timestamp more than 5
minutes from now (`WebhookOptions.tolerance`), so a captured request can't be replayed later. Verify the
**raw body** (`byte[]`) you received, before parsing it. Each event has a unique `id()`: store the ones you
have handled and drop repeats.

```java
// Spring Boot
@PostMapping(value = "/callio/webhook", consumes = "application/json")
ResponseEntity<Void> webhook(@RequestBody byte[] body, @RequestHeader HttpHeaders headers) {
  WebhookEvent ev;
  try {
    ev = Webhooks.parseRequest(body, headers::getFirst, System.getenv("CALLIO_WEBHOOK_SECRET"), null);
  } catch (WebhookVerificationException e) {
    return ResponseEntity.status(401).build();
  }
  if (alreadyHandled(ev.id())) return ResponseEntity.noContent().build();
  switch (ev.type()) {
    case "order.assigned": log.info("{} → {} by {}", ev.order().id(), ev.order().agent(), ev.by()); break;
    case "recording.ready": queueFetch(ev.recordingId()); break;   // metadata only, never audio
    default: break;                                                // new types may be added
  }
  return ResponseEntity.noContent().build();
}
```

With the Servlet API, pass `request::getHeader`; a `Map<String, ?>` of headers (any case, String or list
values) works too. A request without `X-Callio-Timestamp` is rejected. While some senders still use only the
legacy header, pass `new WebhookOptions().allowLegacy(true)` to fall back to `X-NGX-Signature` (body only,
so such a request could be a replay). `Webhooks.verifyRequest` only checks. The older
`Webhooks.verify(body, signatureHeader, secret)` / `parse` still work but are deprecated: they check only
the legacy signature.

Event types include `order.created`, `order.assigned`, `order.closed`, `order.reopened` (with `order()` and
`by()`); `call.*` and `chat.*`; `recording.ready`; `cc.chat-escalated`; `report.snapshot`. Ignore types you
don't handle. Delivery is best-effort with no retries today, so use `events().iterate()` to catch up after
downtime.

## Security

- **Keep the key on your server.** It can read every user, order and recording of your organisation. Never
  put it in a mobile app, a web page or a repository. The app gets a short-lived token from your backend
  instead (`tokens().forUser`).
- **Restrict where the key works.** In the console, *Server API access* (`apiIpAllowlist`) limits your
  organisation's keys to your servers' networks. Calls from other networks get `403`.
- **Rotate keys.** Create the new key, deploy it, then revoke the old one in the console. A revoked key gets
  `401` immediately.
- **The SDK never logs the key.** It is sent only in the `Authorization` header, never in URLs or
  exceptions, and `toString()` of the client, its builder and its HTTP layer leave it out. Recording reasons
  are sent as a query parameter, so don't put personal data in them.
- **Redirects are never followed** (`HttpClient.Redirect.NEVER`; a custom `HttpClient` that follows them is
  refused). A 3xx throws `RedirectException`, so the key can't be carried to another host.
- **HTTPS only.** `http://` is refused unless you call `allowInsecure(true)`, meant for a local stack.
- **Ids are checked.** An empty, `.` or `..` id or username is rejected before any request is built.

## Development

```sh
mvn test                                   # unit tests (scripted Transport + a loopback server)
CALLIO_ADMIN_PASS=… mvn test -Pintegration  # against a running stack
mvn package                                # target/callio-server-0.1.0.jar
```

No JDK? Use Docker: `docker run --rm -v "$PWD":/src -w /src maven:3-eclipse-temurin-21 mvn test` (for the
integration test, add `-e CALLIO_ADMIN_PASS=… -e CALLIO_URL=http://host.docker.internal:8080`). The
library compiles with `--release 11`.

The integration test signs in to the admin API (`CALLIO_URL`, default `http://localhost:8080`;
`CALLIO_ADMIN_USER`, default `admin`). It creates a temporary API key for `CALLIO_TENANT` (default `lab`),
runs every resource, and then deletes what it created and revokes the key. Set `CALLIO_IT_AUDIO=1` to also
download one recording.

Versioning: the package starts at 0.1.0 (`Version.VERSION`) and follows the tenant API (`/api/v1`),
independently of the mobile SDKs.
