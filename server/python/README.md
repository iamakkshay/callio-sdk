# callio-server (Python)

The Callio **server SDK for Python**: what your backend uses to call Callio's tenant API. It creates and
manages app users, issues the short-lived tokens your mobile app signs in with, links customers and agents
through orders, fetches recordings and transcripts, follows the event feed and call records, and verifies
the webhooks Callio sends you.

- Type hints throughout (`py.typed`; responses are `TypedDict`s).
- Typed exceptions.
- Retries with backoff where they are safe.
- Streamed recording downloads.
- **Standard library only** (`urllib`), no dependencies. Python 3.9 or later.

The API itself is described in [docs/TENANT_API.md](../../../docs/TENANT_API.md) and as OpenAPI at
`https://<your-callio-host>/api/v1/openapi.json`.

## Install

The package is not on PyPI yet. Install it from a checkout of this repository, or from git:

```sh
pip install /path/to/ngx-p2p/sdk/server/python
# or
pip install "git+https://<your-git-host>/ngx-p2p.git#subdirectory=sdk/server/python"
```

Once published it will be `pip install callio-server`. Import it as `callio_server`.

## Quick start: give your app a token

Create an API key in the Callio admin console (your organisation → **API keys**). Keep it in your server's
secret store.

```python
import os
from callio_server import Callio

callio = Callio(
    api_key=os.environ["CALLIO_API_KEY"],   # cio_<id>_<secret>
    base_url="https://api.example.sa",      # your Callio host
)

# Your app asks your backend for a Callio token after the user signs in to *your* system.
@app.post("/callio-token")
def callio_token(user=Depends(current_user)):
    t = callio.tokens.for_user(f"cust-{user.id}", display_name=user.name, user_type="customer", ttl_sec=900)
    return {"token": t["token"], "expiresAt": t["expiresAt"]}   # the mobile SDK's tokenProvider returns this token
```

`tokens.for_user()` creates the Callio user the first time it sees them; a `409 user exists` from the API
means they already exist. Then it issues a token. An existing user's name and type are not changed; use
`users.update()` for that.

## Options

`Callio(api_key=None, base_url=None, *, timeout=30.0, max_retries=2, user_agent=None, allow_insecure=False)`

| | Default | |
|---|---|---|
| `api_key` | `$CALLIO_API_KEY` | Required |
| `base_url` | `$CALLIO_BASE_URL` | Required, `https://…` |
| `allow_insecure` | `False` | Development only: accept an `http://` base_url (a local stack or lab box) |
| `timeout` | `30.0` | Seconds per attempt |
| `max_retries` | `2` | Retries for idempotent requests |
| `user_agent` | | Appended to `User-Agent: callio-server-python/<version> python/<version>` |

The client is synchronous. In an async framework (FastAPI, aiohttp), call it with
`await asyncio.to_thread(callio.tokens.for_user, ...)` or in a `def` (thread-pool) endpoint.

## Resources

Python keyword arguments are snake_case; the returned dicts keep the API's camelCase field names.

### Users

```python
u = callio.users.create("cust-42", display_name="Sara", user_type="customer")
u["extension"]               # SIP extension
u.get("initialPassword")     # only when no login_password was given, returned once

callio.users.get("cust-42")
callio.users.list(q="sara", type="customer", status="active")
callio.users.update("cust-42", display_name="Sara A.", segment="vip")   # segment=None clears it
callio.users.disable("cust-42")      # ends their sessions; enable() reverses it
callio.users.sign_out("cust-42")     # end every open session

# Data-subject requests (PDPL)
data = callio.users.export("cust-42")
callio.users.delete("cust-42", reason="customer request #881")   # irreversible erasure
```

### Tokens

```python
t = callio.tokens.create("cust-42", ttl_sec=600)        # 60–3600 s → {"token", "userType", "expiresAt"}
t = callio.tokens.for_user("drv-7", display_name="Omar", user_type="agent")   # also t["created"]
```

### Orders

```python
callio.orders.create("ORD-1001", customer="cust-42", label="Grocery delivery")
callio.orders.assign("ORD-1001", "drv-7")     # the next call goes to drv-7
callio.orders.assign("ORD-1001", None)        # unassign
callio.orders.close("ORD-1001")               # with "only during an active order", calls stop
callio.orders.reopen("ORD-1001")
callio.orders.update("ORD-1001", label="Pharmacy")
callio.orders.get("ORD-1001")
callio.orders.list(status="active", user="cust-42")
```

### Recordings

Every audio or transcript fetch needs a **reason** of at least 5 characters, and is written to the
recording's access trail.

```python
recs = callio.recordings.list(from_="2026-11-01", order_id="ORD-1001", min_duration=10)
meta = callio.recordings.get(recs[0]["id"])

# Stream to a file (or any binary file object); never buffered whole in memory
n = callio.recordings.download(meta["id"], "call.ogg", reason="dispute #4411")

# Or read the stream yourself
with callio.recordings.audio(meta["id"], reason="QA review") as audio:
    audio.content_type                  # audio/ogg: stereo Opus, caller on the left
    for chunk in audio.iter_bytes():
        s3_upload.write(chunk)

tr = callio.recordings.transcript(meta["id"], reason="QA review")   # NotFoundError until it is ready
```

A deleted recording raises `GoneError` (410).

### Groups (group chats)

```python
callio.groups.create("ORD-1001", name="Order 1001", members=["cust-42", "drv-7", "support-1"])
callio.groups.update("ORD-1001", add=["drv-9"], remove=["drv-7"], name="Order 1001 (reassigned)")
callio.groups.get("ORD-1001")
callio.groups.list()
callio.groups.delete("ORD-1001")   # and its messages
```

Groups have 2–50 members. A member added later sees messages from when they joined.

### Events (BI feed) and call records

```python
page = callio.events.list(after=last_seen_id, types=["call.", "order."], limit=1000)   # {"events", "next"}

# Or every event until caught up; store the last id and resume from it next time
for e in callio.events.iterate(after=last_seen_id, types=["call."]):
    warehouse.insert(e)
    last_seen_id = e["id"]

calls = callio.cdr.list(days=7, type="customer")["calls"]   # one row per call
```

### Anything else

`callio.http.request(method, path, query=..., body=...)` calls any endpoint with the same auth, retries and
errors.

## Errors

Every failure is a `CallioError` with `status` (0 when no response arrived), `message` (the server's
`error` text), `body` and `request` (`"GET /api/v1/orders/X"`).

| Class | Status | When |
|---|---|---|
| `ValidationError` | 400 | Bad input: id or username format, unknown user, wrong user type, missing reason |
| `AuthenticationError` | 401 | Missing, wrong or revoked key |
| `PermissionDeniedError` | 403 | Organisation suspended, seat quota reached, user disabled (tokens), or *"this network (x) is not allowed to use this organisation's API"* |
| `NotFoundError` | 404 | No such user, order, group or recording; no transcript yet |
| `ConflictError` | 409 | The user or order id already exists |
| `GoneError` | 410 | The recording was deleted |
| `RateLimitError` | 429 | Over the organisation's request rate; `retry_after` (seconds) from `Retry-After` |
| `ServerError` | 5xx | Platform error |
| `APIConnectionError` / `APITimeoutError` | 0 | No response, or none within `timeout` |

```python
from callio_server import ConflictError, RateLimitError

try:
    callio.orders.create(order_id, customer=customer)
except ConflictError:
    pass                                  # already pushed
except RateLimitError as e:
    time.sleep(e.retry_after or 1)        # then retry
```

**Retries.** `GET` and `DELETE` requests are retried up to `max_retries` times on 429, 5xx and network
errors. The SDK waits `Retry-After` when the server sends it, otherwise uses exponential backoff with
jitter. `POST` and `PATCH` (create user, create order, issue token, reassign…) are never retried
automatically, so a request is never applied twice. Handle `RateLimitError` for those yourself.

## Webhooks

Callio POSTs each event as JSON to your organisation's webhook URL with three headers:

| Header | Value |
|---|---|
| `X-Callio-Timestamp` | Unix seconds when the delivery was signed |
| `X-Callio-Signature` | `v1=<hex HMAC-SHA256(secret, timestamp + "." + raw_body)>` |
| `X-NGX-Signature` | `sha256=<hex HMAC-SHA256(secret, raw_body)>` (legacy, body only) |

Each event body carries a unique `id`. Pass the **raw body** and the **request headers** to
`parse_webhook`. It checks the v1 signature with `hmac.compare_digest`, and it rejects a timestamp more
than 300 seconds from your clock, so a captured delivery can't be replayed later. To stop a replay inside
that window, store each `event.id` and drop any you've already seen.

Flask:

```python
from flask import Flask, request, abort
from callio_server import parse_webhook, WebhookVerificationError

app = Flask(__name__)

@app.post("/callio/webhook")
def callio_webhook():
    try:
        event = parse_webhook(request.get_data(), request.headers, os.environ["CALLIO_WEBHOOK_SECRET"])
    except WebhookVerificationError:
        abort(401)
    if event.id and not seen_store.add(event.id, ttl=600):   # a repeat delivery
        return "", 204
    if event.type == "order.assigned":
        print(event["order"]["id"], "->", event["order"]["agent"], "by", event["by"])
    elif event.type == "recording.ready":
        queue_fetch(event["recordingId"])      # metadata only, never audio
    return "", 204
```

FastAPI:

```python
from fastapi import FastAPI, Request, HTTPException, Response
from callio_server import parse_webhook, WebhookVerificationError

app = FastAPI()

@app.post("/callio/webhook")
async def callio_webhook(request: Request):
    raw = await request.body()                 # the raw bytes, not the parsed JSON
    try:
        event = parse_webhook(raw, request.headers, os.environ["CALLIO_WEBHOOK_SECRET"])
    except WebhookVerificationError:
        raise HTTPException(status_code=401)
    ...
    return Response(status_code=204)
```

`verify_webhook(raw_body, headers, secret, *, tolerance=300, allow_legacy=False)` returns a bool if you only
need the check. `headers` can be any mapping with `.get` (a dict, Flask's or Starlette's
`request.headers`); names are matched without regard to case. `tolerance` is how far, in seconds, the
timestamp may be from now. With `allow_legacy=True`, a delivery that has no `X-Callio-Timestamp` is
checked against the body-only `X-NGX-Signature` instead. That signature has no replay protection, so
turn this on only while you still get deliveries from an older platform version.

The older call form `verify_webhook(raw_body, request.headers.get("X-NGX-Signature"), secret)` still works
but is deprecated: it checks only the legacy body signature. `sign_webhook_v1(body, secret, ts)` builds a
v1 signature for your own tests. `parse_webhook` returns a `WebhookEvent`: a dict with `.id`, `.type`,
`.tenant_id`, `.at` and `.is_order_event`. Event types include:
- `order.created`, `order.assigned`, `order.closed`, `order.reopened` (with `order` and `by`);
- `call.*` and `chat.*`;
- `recording.ready`;
- `cc.chat-escalated`;
- `report.snapshot`.

Ignore types you don't handle. Delivery is best-effort with no retries today, so use `events.iterate()`
to catch up after downtime.

## Security

- **Keep the key on your server.** It can read every user, order and recording of your organisation.
  Never put it in a mobile app, a web page or a repository. The app gets a short-lived token from your
  backend instead (`tokens.for_user`).
- **Restrict where the key works.** In the console, *Server API access* (`apiIpAllowlist`) limits your
  organisation's keys to your servers' networks. A leaked key is then useless anywhere else; calls from
  other networks get `403` (`PermissionDeniedError`).
- **Rotate keys.** Create the new key, deploy it, then revoke the old one in the console. A revoked key
  gets `401` immediately.
- **The SDK never logs the key.** The key is sent only in the `Authorization` header, never in URLs,
  exceptions or `repr()`. The SDK does not log anything. Recording reasons are sent as a query parameter,
  so don't put personal data in them.
- **Use HTTPS.** The client refuses an `http://` base_url unless you pass `allow_insecure=True`. Use that
  only against a local stack or a lab box.
- **Redirects are refused.** If the API answers with a 3xx, the client raises a `CallioError` and doesn't
  follow it. urllib would otherwise re-send the `Authorization` header to the new location. Set
  `base_url` to the final `https://` address.
- **Ids are validated.** An empty id, or an id of `.` or `..`, is rejected before any request is sent.

## Development

```sh
python3 -m unittest discover -s tests -v                                  # unit tests (mocked HTTP); integration skipped
CALLIO_ADMIN_PASS=… python3 -m unittest tests.test_integration -v           # against a running stack
python3 -m build                                                          # sdist + wheel (pip install build)
```

The integration test signs in to the admin API (`CALLIO_URL`, default `http://localhost:8080`;
`CALLIO_ADMIN_USER`, default `admin`). It creates a temporary API key for `CALLIO_TENANT` (default
`lab`), runs every resource, and then deletes what it created and revokes the key. Set
`CALLIO_IT_AUDIO=1` to also download one recording.

Versioning: the package starts at 0.1.0 and follows the tenant API (`/api/v1`), independently of the
mobile SDKs.
