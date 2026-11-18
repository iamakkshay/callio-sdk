# Callio server SDK for Go

The Callio **server SDK for Go**: what your backend uses to call Callio's tenant API. It creates and manages
app users, issues the short-lived tokens your mobile app signs in with, links customers and agents through
orders, fetches recordings and transcripts, follows the event feed and call records, and verifies the
webhooks Callio sends you.

- Standard library only (`net/http`, `encoding/json`), no dependencies. Go 1.23 or later.
- `context.Context` on every call.
- Typed errors that work with `errors.Is` / `errors.As`.
- Retries with backoff where they are safe.
- Streamed recording downloads.

The API itself is described in [docs/TENANT_API.md](../../../docs/TENANT_API.md) and as OpenAPI at
`https://<your-callio-host>/api/v1/openapi.json`. Behaviour matches the [Node.js](../node/README.md) and
[Python](../python/README.md) server SDKs.

## Install

The module lives in the `server/go` folder of the public SDK repository:

```sh
go get github.com/iamakkshay/callio-sdk/server/go@v0.1.0
```

Import it as `callio`.

## Quick start: give your app a token

Create an API key in the Callio admin console (your organisation → **API keys**). Keep it in your server's
secret store.

```go
import callio "github.com/iamakkshay/callio-sdk/server/go"

client, err := callio.New(
	callio.WithAPIKey(os.Getenv("CALLIO_API_KEY")), // cio_<id>_<secret>
	callio.WithBaseURL("https://api.example.sa"),   // your Callio host
)
if err != nil { log.Fatal(err) }

// Your app asks your backend for a Callio token after the user signs in to *your* system.
http.HandleFunc("POST /callio-token", func(w http.ResponseWriter, r *http.Request) {
	user := currentUser(r) // your auth
	t, err := client.Tokens.ForUser(r.Context(), "cust-"+user.ID, callio.ForUserOptions{
		DisplayName: user.Name,
		UserType:    callio.UserTypeCustomer, // or UserTypeAgent for drivers, support staff…
		TTLSec:      900,
	})
	if err != nil { http.Error(w, "callio unavailable", http.StatusBadGateway); return }
	json.NewEncoder(w).Encode(map[string]string{"token": t.Token, "expiresAt": t.ExpiresAt}) // the mobile SDK's tokenProvider returns this token
})
```

`Tokens.ForUser` creates the Callio user the first time it sees them; a `409 user exists` from the API
means they already exist. Then it issues a token (`t.Created` says which). An existing user's name and type
are not changed; use `Users.Update` for that.

## Options

| Option | Default | |
|---|---|---|
| `WithAPIKey` | `$CALLIO_API_KEY` | Required |
| `WithBaseURL` | `$CALLIO_BASE_URL` | Required, `https://…` |
| `WithAllowInsecure(true)` | off | Permit `http://` (a local stack only) |
| `WithTimeout` | `30s` | Per attempt |
| `WithMaxRetries` | `2` | Retries for idempotent requests |
| `WithHTTPClient` | `&http.Client{}` | Proxies, tests, instrumentation. Its redirect policy is overridden (see Security) |
| `WithUserAgent` | | Appended to `User-Agent: callio-server-go/<version> go/<version>` |

## Resources

Optional fields are zero values; PATCH fields that can be cleared use `callio.Set(v)` / `callio.Null[T]()`.

### Users

```go
u, err := client.Users.Create(ctx, callio.CreateUserParams{Username: "cust-42", DisplayName: "Sara", UserType: callio.UserTypeCustomer})
u.Extension        // SIP extension
u.InitialPassword  // only when no LoginPassword was given, returned once

client.Users.Get(ctx, "cust-42")
client.Users.List(ctx, callio.ListUsersParams{Q: "sara", Type: callio.UserTypeCustomer, Status: "active"})
client.Users.Update(ctx, "cust-42", callio.UpdateUserParams{DisplayName: "Sara A.", Segment: callio.Set("vip")})
client.Users.Update(ctx, "cust-42", callio.UpdateUserParams{Phone: callio.Null[string]()}) // clear
client.Users.Disable(ctx, "cust-42") // ends their sessions; Enable reverses it
client.Users.SignOut(ctx, "cust-42") // end every open session

// Data-subject requests (PDPL)
data, _ := client.Users.Export(ctx, "cust-42")
client.Users.Delete(ctx, "cust-42", "customer request #881") // irreversible erasure
```

### Tokens

```go
t, _ := client.Tokens.Create(ctx, callio.CreateTokenParams{Username: "cust-42", TTLSec: 600}) // 60–3600 s
ut, _ := client.Tokens.ForUser(ctx, "drv-7", callio.ForUserOptions{DisplayName: "Omar", UserType: callio.UserTypeAgent}) // ut.Created
```

### Orders

```go
client.Orders.Create(ctx, callio.CreateOrderParams{ID: "ORD-1001", Customer: "cust-42", Label: "Grocery delivery"})
client.Orders.Assign(ctx, "ORD-1001", "drv-7") // the next call goes to drv-7
client.Orders.Unassign(ctx, "ORD-1001")        // or Assign(ctx, id, "")
client.Orders.Close(ctx, "ORD-1001")           // with "only during an active order", calls stop
client.Orders.Reopen(ctx, "ORD-1001")
client.Orders.Update(ctx, "ORD-1001", callio.UpdateOrderParams{Label: callio.Set("Pharmacy")})
client.Orders.Get(ctx, "ORD-1001")
client.Orders.List(ctx, callio.ListOrdersParams{Status: callio.OrderActive, User: "cust-42"})
```

### Recordings

Every audio or transcript fetch needs a **reason** of at least 5 characters, and is written to the
recording's access trail.

```go
recs, _ := client.Recordings.List(ctx, callio.ListRecordingsParams{From: time.Now().AddDate(0, 0, -7), OrderID: "ORD-1001", MinDuration: 10})
meta, _ := client.Recordings.Get(ctx, recs[0].ID)

// Stream to a file (never buffered whole in memory)
n, err := client.Recordings.Download(ctx, meta.ID, "./call.ogg", "dispute #4411")

// Or take the stream yourself, e.g. to proxy it
a, err := client.Recordings.Audio(ctx, meta.ID, "QA review")
defer a.Body.Close()
w.Header().Set("Content-Type", a.ContentType) // audio/ogg: stereo Opus, caller on the left
io.Copy(w, a.Body)

tr, err := client.Recordings.Transcript(ctx, meta.ID, "QA review") // ErrNotFound until it is ready
```

A deleted recording returns `ErrGone` (410). `DownloadTo(ctx, id, w, reason)` writes to any `io.Writer`.

### Groups (group chats)

```go
client.Groups.Create(ctx, callio.CreateGroupParams{ID: "ORD-1001", Name: "Order 1001", Members: []string{"cust-42", "drv-7", "support-1"}})
client.Groups.Update(ctx, "ORD-1001", callio.UpdateGroupParams{Add: []string{"drv-9"}, Remove: []string{"drv-7"}, Name: "Order 1001 (reassigned)"})
client.Groups.Get(ctx, "ORD-1001")
client.Groups.List(ctx)
client.Groups.Delete(ctx, "ORD-1001") // and its messages
```

Groups have 2–50 members. A member added later sees messages from when they joined.

### Events (BI feed) and call records

```go
// One page at a time
page, _ := client.Events.List(ctx, callio.ListEventsParams{After: lastSeenID, Types: []string{"call.", "order."}, Limit: 1000})

// Or every event until caught up; store the last id and resume from it next time
for e, err := range client.Events.Iterate(ctx, callio.ListEventsParams{After: lastSeenID, Types: []string{"call."}}) {
	if err != nil { return err }
	warehouse.Insert(e)
	lastSeenID = e.ID
}

cdr, _ := client.CDR.List(ctx, callio.ListCdrParams{Days: 7, Type: callio.UserTypeCustomer}) // one row per call
```

### Anything else

`client.HTTP.Request(ctx, method, path, &callio.RequestOptions{Query: q, Body: b}, &out)` calls any
endpoint with the same auth, retries and errors; `client.HTTP.RequestRaw` returns the open
`*http.Response` for streaming.

## Errors

Every API failure is a `*callio.Error` with `Status` (0 when no response arrived), `Message` (the server's
`error` text), `Body` and `Request` (`"GET /api/v1/orders/X"`). Branch with `errors.Is`:

| Sentinel | Status | When |
|---|---|---|
| `ErrValidation` | 400 | Bad input: id or username format, unknown user, wrong user type, missing reason |
| `ErrAuthentication` | 401 | Missing, wrong or revoked key |
| `ErrPermissionDenied` | 403 | Organisation suspended, seat quota reached, user disabled (tokens), or *"this network (x) is not allowed to use this organisation's API"* |
| `ErrNotFound` | 404 | No such user, order, group or recording; no transcript yet |
| `ErrConflict` | 409 | The user or order id already exists |
| `ErrGone` | 410 | The recording was deleted |
| `ErrRateLimit` | 429 | Over the organisation's request rate; `RetryAfter` from `Retry-After` |
| `ErrServer` | 5xx | Platform error |
| `ErrRedirect` | 3xx | The server redirected; never followed (see Security) |
| `ErrConnection` / `ErrTimeout` | 0 | No response, or none within the timeout (`ErrTimeout` also matches `ErrConnection`) |
| `ErrInvalidArgument` | | Checked before any request: empty, `.` or `..` id; reason under 5 characters |

A cancelled or expired `ctx` returns `ctx.Err()` as is.

```go
_, err := client.Orders.Create(ctx, callio.CreateOrderParams{ID: id, Customer: customer})
var ce *callio.Error
switch {
case errors.Is(err, callio.ErrConflict): // already pushed
case errors.Is(err, callio.ErrRateLimit) && errors.As(err, &ce) && ce.RetryAfter != nil:
	time.Sleep(*ce.RetryAfter) // then retry
case err != nil:
	return err
}
```

**Retries.** `GET`, `HEAD`, `PUT`, `DELETE` and `OPTIONS` requests are retried up to `MaxRetries` times on
429, 5xx and network errors. The SDK waits `Retry-After` when the server sends it (capped at 60 s),
otherwise uses exponential backoff with jitter. `POST` and `PATCH` (create user, create order, issue token,
reassign…) are never retried automatically, so a request is never applied twice. Handle `ErrRateLimit` for
those yourself.

## Webhooks

Callio POSTs each event as JSON to your organisation's webhook URL and signs it with your webhook secret:

```
X-Callio-Timestamp: <unix seconds>
X-Callio-Signature: v1=<hex HMAC-SHA256(secret, timestamp + "." + rawBody)>
X-NGX-Signature:    sha256=<hex HMAC-SHA256(secret, rawBody)>      (legacy)
```

`ParseWebhookRequest` checks the `v1` signature in constant time, and rejects a timestamp more than 5
minutes from now (`WebhookOptions.Tolerance`), so a captured request can't be replayed later. Verify the
**raw body** you received, before parsing it. Each event has a unique `ID`: store the ones you have handled
and drop repeats.

```go
http.HandleFunc("POST /callio/webhook", func(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil { http.Error(w, "too large", http.StatusRequestEntityTooLarge); return }
	ev, err := callio.ParseWebhookRequest(body, r.Header, os.Getenv("CALLIO_WEBHOOK_SECRET"), nil)
	if err != nil { w.WriteHeader(http.StatusUnauthorized); return }
	if alreadyHandled(ev.ID) { w.WriteHeader(http.StatusNoContent); return }
	switch ev.Type {
	case "order.assigned":
		log.Println(ev.Order.ID, "→", *ev.Order.Agent, "by", ev.By)
	case "recording.ready":
		queueFetch(ev.RecordingID) // metadata only, never audio
	default: // new types may be added
	}
	w.WriteHeader(http.StatusNoContent)
})
```

A request without `X-Callio-Timestamp` is rejected. While some senders still use only the legacy header,
pass `&callio.WebhookOptions{AllowLegacy: true}` to fall back to `X-NGX-Signature` (body only, so such a
request could be a replay). `VerifyWebhookRequest` returns just the error. The older
`VerifyWebhook(body, signatureHeader, secret)` / `ParseWebhook` still work but are deprecated: they check
only the legacy signature.

Event types include `order.created`, `order.assigned`, `order.closed`, `order.reopened` (with `Order` and
`By`); `call.*` and `chat.*`; `recording.ready`; `cc.chat-escalated`; `report.snapshot`. `ev.Raw` holds the
whole body. Ignore types you don't handle. Delivery is best-effort with no retries today, so use
`Events.Iterate` to catch up after downtime.

## Security

- **Keep the key on your server.** It can read every user, order and recording of your organisation. Never
  put it in a mobile app, a web page or a repository. The app gets a short-lived token from your backend
  instead (`Tokens.ForUser`).
- **Restrict where the key works.** In the console, *Server API access* (`apiIpAllowlist`) limits your
  organisation's keys to your servers' networks. Calls from other networks get `403`.
- **Rotate keys.** Create the new key, deploy it, then revoke the old one in the console. A revoked key gets
  `401` immediately.
- **The SDK never logs the key.** It is sent only in the `Authorization` header, never in URLs or errors;
  `fmt` (`%v`, `%+v`, `%#v`) and `json.Marshal` of the client leave it out. Recording reasons are sent as a
  query parameter, so don't put personal data in them.
- **Redirects are never followed.** A 3xx returns `ErrRedirect` instead, so the key can't be carried to
  another host. This also applies to a client passed with `WithHTTPClient` (the SDK uses a copy with its own
  redirect policy).
- **HTTPS only.** `http://` is refused unless you pass `WithAllowInsecure(true)`, meant for a local stack.
- **Ids are checked.** An empty, `.` or `..` id or username is rejected before any request is built.

## Development

```sh
go vet ./... && go test ./...                                     # unit tests with a scripted RoundTripper
CALLIO_ADMIN_PASS=… go test -run TestIntegration -v ./...           # against a running stack
```

The integration test signs in to the admin API (`CALLIO_URL`, default `http://localhost:8080`;
`CALLIO_ADMIN_USER`, default `admin`). It creates a temporary API key for `CALLIO_TENANT` (default `lab`),
runs every resource, and then deletes what it created and revokes the key. Set `CALLIO_IT_AUDIO=1` to also
download one recording.

Versioning: the module starts at 0.1.0 (`callio.Version`) and follows the tenant API (`/api/v1`),
independently of the mobile SDKs.
