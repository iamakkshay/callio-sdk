# @apurohit2/callio-server

The Callio **server SDK for Node.js**: what your backend uses to call Callio's tenant API. It creates and
manages app users, issues the short-lived tokens your mobile app signs in with, links customers and agents
through orders, fetches recordings and transcripts, follows the event feed and call records, and verifies
the webhooks Callio sends you.

- TypeScript types for every request and response.
- Typed errors.
- Retries with backoff where they are safe.
- Streamed recording downloads.
- No runtime dependencies: it uses the global `fetch` of Node.js 18 or later.

The API itself is described in [docs/TENANT_API.md](../../../docs/TENANT_API.md) and as OpenAPI at
`https://<your-callio-host>/api/v1/openapi.json`.

## Install

The package is not on npm yet. Install it from a checkout of this repository, or from git:

```sh
# from a local checkout (builds dist/ on pack)
cd sdk/server/node && npm install && npm run build && npm pack
npm install /path/to/clarigoinfotech-callio-server-0.1.0.tgz

# or reference the folder directly from your backend's package.json
npm install /path/to/ngx-p2p/sdk/server/node     # run `npm install && npm run build` in that folder first
```

Once published it will be `npm install @apurohit2/callio-server`.

## Quick start: give your app a token

Create an API key in the Callio admin console (your organisation → **API keys**). Keep it in your server's
secret store.

```ts

> **Private package.** Install it with your organisation's SDK install token (console → Security & data → SDK install
> tokens). Add two lines to your app's `.npmrc`, where `<platform>` is your Callio address, and set `CALLIO_SDK_TOKEN`
> in your environment or build server (keep it secret; don't commit it):
>
> ```ini
> @apurohit2:registry=https://<platform>/npm/
> //<platform>/npm/:_authToken=${CALLIO_SDK_TOKEN}
> ```
import { Callio } from '@apurohit2/callio-server';

const callio = new Callio({
  apiKey: process.env.CALLIO_API_KEY,      // cio_<id>_<secret>
  baseUrl: 'https://api.example.sa',       // your Callio host
});

// Your app asks your backend for a Callio token after the user signs in to *your* system.
app.post('/callio-token', requireLogin, async (req, res) => {
  const { token, expiresAt } = await callio.tokens.forUser(`cust-${req.user.id}`, {
    displayName: req.user.name,
    userType: 'customer',          // or 'agent' for drivers, support staff…
    ttlSec: 900,
  });
  res.json({ token, expiresAt });  // the mobile SDK's tokenProvider returns this token
});
```

`tokens.forUser()` creates the Callio user the first time it sees them; a `409 user exists` from the API
means they already exist. Then it issues a token. An existing user's name and type are not changed; use
`users.update()` for that.

## Options

| Option | Default | |
|---|---|---|
| `apiKey` | `process.env.CALLIO_API_KEY` | Required |
| `baseUrl` | `process.env.CALLIO_BASE_URL` | Required, `https://…` |
| `allowInsecure` | `false` | Development only: accept an `http://` baseUrl (a local stack or lab box) |
| `timeout` | `30000` | Milliseconds per attempt |
| `maxRetries` | `2` | Retries for idempotent requests |
| `fetch` | `globalThis.fetch` | Replace for proxies, tests or instrumentation |
| `userAgent` | | Appended to `User-Agent: callio-server-node/<version> node/<version>` |

## Resources

### Users

```ts
const u = await callio.users.create({ username: 'cust-42', displayName: 'Sara', userType: 'customer' });
u.extension;            // SIP extension
u.initialPassword;      // only when no loginPassword was given, returned once

await callio.users.get('cust-42');
await callio.users.list({ q: 'sara', type: 'customer', status: 'active' });
await callio.users.update('cust-42', { displayName: 'Sara A.', segment: 'vip' });
await callio.users.disable('cust-42');   // ends their sessions; enable() reverses it
await callio.users.signOut('cust-42');   // end every open session

// Data-subject requests (PDPL)
const data = await callio.users.export('cust-42');
await callio.users.delete('cust-42', { reason: 'customer request #881' });   // irreversible erasure
```

Changing `userType` or disabling a user ends their sessions, so the next token carries the new type.

### Tokens

```ts
const { token, userType, expiresAt } = await callio.tokens.create({ username: 'cust-42', ttlSec: 600 });   // 60–3600 s
const t = await callio.tokens.forUser('drv-7', { displayName: 'Omar', userType: 'agent' });                 // t.created
```

### Orders

```ts
await callio.orders.create({ id: 'ORD-1001', customer: 'cust-42', label: 'Grocery delivery' });
await callio.orders.assign('ORD-1001', 'drv-7');   // the next call goes to drv-7
await callio.orders.assign('ORD-1001', null);      // unassign
await callio.orders.close('ORD-1001');             // with "only during an active order", calls stop
await callio.orders.reopen('ORD-1001');
await callio.orders.update('ORD-1001', { label: 'Pharmacy' });
await callio.orders.get('ORD-1001');
await callio.orders.list({ status: 'active', user: 'cust-42' });
```

### Recordings

Every audio or transcript fetch needs a **reason** of at least 5 characters, and is written to the
recording's access trail.

```ts
const recs = await callio.recordings.list({ from: '2026-11-01', orderId: 'ORD-1001', minDuration: 10 });
const meta = await callio.recordings.get(recs[0].id);

// Stream to a file (never buffered whole in memory)
const bytes = await callio.recordings.download(meta.id, './call.ogg', { reason: 'dispute #4411' });

// Or take the stream yourself, e.g. to pipe to S3 or an HTTP response
import { Readable } from 'node:stream';
const audio = await callio.recordings.audio(meta.id, { reason: 'QA review' });
res.setHeader('Content-Type', audio.contentType);    // audio/ogg: stereo Opus, caller on the left
Readable.fromWeb(audio.body).pipe(res);

const tr = await callio.recordings.transcript(meta.id, { reason: 'QA review' });   // NotFoundError until it is ready
```

A deleted recording throws `GoneError` (410).

### Groups (group chats)

```ts
await callio.groups.create({ id: 'ORD-1001', name: 'Order 1001', members: ['cust-42', 'drv-7', 'support-1'] });
await callio.groups.update('ORD-1001', { add: ['drv-9'], remove: ['drv-7'], name: 'Order 1001 (reassigned)' });
await callio.groups.get('ORD-1001');
await callio.groups.list();
await callio.groups.delete('ORD-1001');   // and its messages
```

Groups have 2–50 members. A member added later sees messages from when they joined.

### Events (BI feed) and call records

```ts
// One page at a time
let { events, next } = await callio.events.list({ after: lastSeenId, types: ['call.', 'order.'], limit: 1000 });

// Or every event until caught up; store the last id and resume from it next time
for await (const e of callio.events.iterate({ after: lastSeenId, types: ['call.'] })) {
  await warehouse.insert(e);
  lastSeenId = e.id;
}

const { calls } = await callio.cdr.list({ days: 7, type: 'customer' });   // one row per call
```

### Anything else

`callio.http.request(method, path, { query, body })` calls any endpoint with the same auth, retries and
errors.

## Errors

Every failure is a `CallioError` with `status` (0 when no response arrived), `message` (the server's
`error` text), `body` and `request` (`"GET /api/v1/orders/X"`). Branch on the subclass:

| Class | Status | When |
|---|---|---|
| `ValidationError` | 400 | Bad input: id or username format, unknown user, wrong user type, missing reason |
| `AuthenticationError` | 401 | Missing, wrong or revoked key |
| `PermissionDeniedError` | 403 | Organisation suspended, seat quota reached, user disabled (tokens), or *"this network (x) is not allowed to use this organisation's API"* |
| `NotFoundError` | 404 | No such user, order, group or recording; no transcript yet |
| `ConflictError` | 409 | The user or order id already exists |
| `GoneError` | 410 | The recording was deleted |
| `RateLimitError` | 429 | Over the organisation's request rate; `retryAfter` (seconds) from `Retry-After` |
| `ServerError` | 5xx | Platform error |
| `ConnectionError` / `TimeoutError` | 0 | No response, or none within `timeout` |

```ts
import { ConflictError, RateLimitError } from '@apurohit2/callio-server';
try {
  await callio.orders.create({ id, customer });
} catch (e) {
  if (e instanceof ConflictError) { /* already pushed */ }
  else if (e instanceof RateLimitError) { await sleep((e.retryAfter ?? 1) * 1000); /* retry */ }
  else throw e;
}
```

**Retries.** `GET` and `DELETE` requests are retried up to `maxRetries` times on 429, 5xx and network
errors. The SDK waits `Retry-After` when the server sends it, otherwise uses exponential backoff with
jitter. `POST` and `PATCH` (create user, create order, issue token, reassign…) are never retried
automatically, so a request is never applied twice. Handle `RateLimitError` for those yourself.

## Webhooks

Callio POSTs each event as JSON to your organisation's webhook URL with three headers:

| Header | Value |
|---|---|
| `X-Callio-Timestamp` | Unix seconds when the delivery was signed |
| `X-Callio-Signature` | `v1=<hex HMAC-SHA256(secret, timestamp + "." + rawBody)>` |
| `X-NGX-Signature` | `sha256=<hex HMAC-SHA256(secret, rawBody)>` (legacy, body only) |

Each event body carries a unique `id`. Pass the **raw body** and the **request headers** to
`parseWebhook`. It checks the v1 signature with a constant-time compare, and it rejects a timestamp more
than 300 seconds from your clock, so a captured delivery can't be replayed later. To stop a replay inside
that window, store each `event.id` and drop any you've already seen.

```ts
import express from 'express';
import { parseWebhook, WebhookVerificationError } from '@apurohit2/callio-server';

const app = express();
app.post('/callio/webhook', express.raw({ type: 'application/json' }), async (req, res) => {
  let event;
  try {
    event = parseWebhook(req.body, req.headers, process.env.CALLIO_WEBHOOK_SECRET!);   // { toleranceSec: 300 }
  } catch (e) {
    if (e instanceof WebhookVerificationError) return res.sendStatus(401);
    throw e;
  }
  if (event.id && !(await seenStore.add(event.id, { ttlSec: 600 }))) return res.sendStatus(204);  // a repeat
  switch (event.type) {
    case 'order.assigned': console.log(event.order.id, '→', event.order.agent, 'by', event.by); break;
    case 'recording.ready': queueFetch(event.recordingId); break;   // metadata only, never audio
    default: break;                                                  // new types may be added
  }
  res.sendStatus(204);
});
```

`verifyWebhook(rawBody, headers, secret, options?)` returns a boolean if you only need the check.
`headers` can be Node/Express `req.headers`, a fetch `Headers` or a `Map`; names are matched without
regard to case. Options:

- `toleranceSec` (default `300`): how far, in seconds, the timestamp may be from now.
- `allowLegacy` (default `false`): accept a delivery that has no `X-Callio-Timestamp` by checking only
  the body-only `X-NGX-Signature`. That signature has no replay protection, so turn this on only while
  you still get deliveries from an older platform version.

The older call form `verifyWebhook(rawBody, req.get('x-ngx-signature'), secret)` still works but is
deprecated: it checks only the legacy body signature. `signWebhookV1(body, secret, ts)` builds a v1
signature for your own tests. Event types include:
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
  backend instead (`tokens.forUser`).
- **Restrict where the key works.** In the console, *Server API access* (`apiIpAllowlist`) limits your
  organisation's keys to your servers' networks. A leaked key is then useless anywhere else; calls from
  other networks get `403` (`PermissionDeniedError`).
- **Rotate keys.** Create the new key, deploy it, then revoke the old one in the console. A revoked key
  gets `401` immediately.
- **The SDK never logs the key.** The key is sent only in the `Authorization` header, never in URLs or
  errors, and `console.log(callio)` / `JSON.stringify(callio)` leave it out. Recording reasons are sent
  as a query parameter, so don't put personal data in them.
- **Use HTTPS.** The client refuses an `http://` baseUrl unless you pass `allowInsecure: true`. Use that
  only against a local stack or a lab box.
- **Redirects are refused.** If the API answers with a 3xx, the client throws a `CallioError` and doesn't
  follow it, so the key is never sent to another host. This doesn't depend on the Node.js version. Set
  `baseUrl` to the final `https://` address.
- **Ids are validated.** An empty id, or an id of `.` or `..`, is rejected before any request is sent.

## Development

```sh
npm install
npm test                      # tsc (strict) + unit tests with a mocked fetch
CALLIO_ADMIN_PASS=… npm run test:integration   # against a running stack; see test/integration.test.mjs
npm pack --dry-run
```

The integration test signs in to the admin API (`CALLIO_URL`, default `http://localhost:8080`;
`CALLIO_ADMIN_USER`, default `admin`). It creates a temporary API key for `CALLIO_TENANT` (default
`lab`), runs every resource, and then deletes what it created and revokes the key. Set
`CALLIO_IT_AUDIO=1` to also download one recording.

Versioning: the package starts at 0.1.0 and follows the tenant API (`/api/v1`), independently of the
mobile SDKs.
