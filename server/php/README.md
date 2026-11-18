# clarigoinfotech/callio-server (PHP)

The Callio **server SDK for PHP**: what your backend uses to call Callio's tenant API. It creates and
manages app users, issues the short-lived tokens your mobile app signs in with, links customers and agents
through orders, fetches recordings and transcripts, follows the event feed and call records, and verifies
the webhooks Callio sends you.

- PHP 8.1 or later, with `ext-curl` and `ext-json` only. No Composer runtime dependencies.
- Typed exceptions.
- Retries with backoff where they are safe.
- Streamed recording downloads.
- PSR-4 (`Clarigoinfotech\Callio\`). Responses are plain arrays, as the API sends them.

The API itself is described in [docs/TENANT_API.md](../../../docs/TENANT_API.md) and as OpenAPI at
`https://<your-callio-host>/api/v1/openapi.json`. Behaviour matches the [Node.js](../node/README.md) and
[Python](../python/README.md) server SDKs.

## Install

The package is not on Packagist yet. Install it from a checkout with a Composer path repository:

```json
{
  "repositories": [{ "type": "path", "url": "/path/to/ngx-p2p/sdk/server/php" }],
  "require": { "clarigoinfotech/callio-server": "^0.1" }
}
```

Once published it will be `composer require clarigoinfotech/callio-server`.

## Quick start: give your app a token

Create an API key in the Callio admin console (your organisation → **API keys**). Keep it in your server's
secret store.

```php
use Clarigoinfotech\Callio\Callio;

$callio = new Callio(
    apiKey: getenv('CALLIO_API_KEY'),     // cio_<id>_<secret>
    baseUrl: 'https://api.example.sa',    // your Callio host
);

// Your app asks your backend for a Callio token after the user signs in to *your* system (Laravel):
Route::post('/callio-token', function (Request $request) use ($callio) {
    $user = $request->user();
    $t = $callio->tokens->forUser("cust-{$user->id}", [
        'displayName' => $user->name,
        'userType' => 'customer',          // or 'agent' for drivers, support staff…
        'ttlSec' => 900,
    ]);
    return ['token' => $t['token'], 'expiresAt' => $t['expiresAt']];   // the mobile SDK's tokenProvider returns this token
})->middleware('auth');
```

`tokens->forUser()` creates the Callio user the first time it sees them; a `409 user exists` from the API
means they already exist. Then it issues a token (`$t['created']` says which). An existing user's name and
type are not changed; use `users->update()` for that. In Laravel, bind the client as a singleton in a
service provider.

## Options (named constructor arguments)

| Argument | Default | |
|---|---|---|
| `apiKey` | `CALLIO_API_KEY` | Required |
| `baseUrl` | `CALLIO_BASE_URL` | Required, `https://…` |
| `allowInsecure: true` | off | Permit `http://` (a local stack only) |
| `timeout` | `30.0` | Seconds per attempt |
| `maxRetries` | `2` | Retries for idempotent requests |
| `transport` | `CurlTransport` | Replace for proxies, tests or instrumentation; `new CurlTransport([CURLOPT_PROXY => …])` adds cURL options |
| `userAgent` | | Appended to `User-Agent: callio-server-php/<version> php/<version>` |

## Resources

Parameters are arrays with the API's field names. Only keys you pass are sent, and a key set to `null` is
sent as JSON null.

### Users

```php
$u = $callio->users->create(['username' => 'cust-42', 'displayName' => 'Sara', 'userType' => 'customer']);
$u['extension'];         // SIP extension
$u['initialPassword'];   // only when no loginPassword was given, returned once

$callio->users->get('cust-42');
$callio->users->list(['q' => 'sara', 'type' => 'customer', 'status' => 'active']);
$callio->users->update('cust-42', ['displayName' => 'Sara A.', 'segment' => 'vip']);
$callio->users->update('cust-42', ['phone' => null]);   // clear
$callio->users->disable('cust-42');   // ends their sessions; enable() reverses it
$callio->users->signOut('cust-42');   // end every open session

// Data-subject requests (PDPL)
$data = $callio->users->export('cust-42');
$callio->users->delete('cust-42', 'customer request #881');   // irreversible erasure
```

### Tokens

```php
$t = $callio->tokens->create('cust-42', ttlSec: 600);                                       // 60–3600 s
$t = $callio->tokens->forUser('drv-7', ['displayName' => 'Omar', 'userType' => 'agent']);   // $t['created']
```

### Orders

```php
$callio->orders->create(['id' => 'ORD-1001', 'customer' => 'cust-42', 'label' => 'Grocery delivery']);
$callio->orders->assign('ORD-1001', 'drv-7');   // the next call goes to drv-7
$callio->orders->assign('ORD-1001', null);      // unassign
$callio->orders->close('ORD-1001');             // with "only during an active order", calls stop
$callio->orders->reopen('ORD-1001');
$callio->orders->update('ORD-1001', ['label' => 'Pharmacy']);
$callio->orders->get('ORD-1001');
$callio->orders->list(['status' => 'active', 'user' => 'cust-42']);
```

### Recordings

Every audio or transcript fetch needs a **reason** of at least 5 characters, and is written to the
recording's access trail.

```php
$recs = $callio->recordings->list(['from' => new DateTimeImmutable('-7 days'), 'orderId' => 'ORD-1001', 'minDuration' => 10]);
$meta = $callio->recordings->get($recs[0]['id']);

// Stream to a file (written as it arrives, never held in a PHP string)
$bytes = $callio->recordings->download($meta['id'], '/tmp/call.ogg', reason: 'dispute #4411');
// …or to any writable stream: download($id, fopen('php://output', 'wb'), reason: …)

// Or take a stream (spooled to php://temp: memory up to 2 MB, then a temp file)
$a = $callio->recordings->audio($meta['id'], reason: 'QA review');
header('Content-Type: ' . $a->contentType);   // audio/ogg: stereo Opus, caller on the left
fpassthru($a->stream());
$a->close();

$tr = $callio->recordings->transcript($meta['id'], reason: 'QA review');   // NotFoundException until it is ready
```

A deleted recording throws `GoneException` (410).

### Groups (group chats)

```php
$callio->groups->create(['id' => 'ORD-1001', 'name' => 'Order 1001', 'members' => ['cust-42', 'drv-7', 'support-1']]);
$callio->groups->update('ORD-1001', ['add' => ['drv-9'], 'remove' => ['drv-7'], 'name' => 'Order 1001 (reassigned)']);
$callio->groups->get('ORD-1001');
$callio->groups->list();
$callio->groups->delete('ORD-1001');   // and its messages
```

Groups have 2–50 members. A member added later sees messages from when they joined.

### Events (BI feed) and call records

```php
// One page at a time
['events' => $events, 'next' => $next] = $callio->events->list(['after' => $lastSeenId, 'types' => ['call.', 'order.'], 'limit' => 1000]);

// Or every event until caught up (a generator); store the last id and resume from it next time
foreach ($callio->events->iterate(['after' => $lastSeenId, 'types' => ['call.']]) as $e) {
    $warehouse->insert($e);
    $lastSeenId = $e['id'];
}

$cdr = $callio->cdr->list(['days' => 7, 'type' => 'customer']);   // one row per call
```

### Anything else

`$callio->http->request($method, $path, $query, $body)` calls any endpoint with the same auth, retries and
errors.

## Errors

Every failure from the API is a `Clarigoinfotech\Callio\Exception\CallioException` with `getStatus()` (0
when no response arrived), `getMessage()` (the server's `error` text), `getBody()` and `getRequest()`
(`"GET /api/v1/orders/X"`). Catch the subclass:

| Class | Status | When |
|---|---|---|
| `ValidationException` | 400 | Bad input: id or username format, unknown user, wrong user type, missing reason |
| `AuthenticationException` | 401 | Missing, wrong or revoked key |
| `PermissionDeniedException` | 403 | Organisation suspended, seat quota reached, user disabled (tokens), or *"this network (x) is not allowed to use this organisation's API"* |
| `NotFoundException` | 404 | No such user, order, group or recording; no transcript yet |
| `ConflictException` | 409 | The user or order id already exists |
| `GoneException` | 410 | The recording was deleted |
| `RateLimitException` | 429 | Over the organisation's request rate; `getRetryAfter()` (seconds) from `Retry-After` |
| `ServerException` | 5xx | Platform error |
| `RedirectException` | 3xx | The server redirected; never followed (see Security) |
| `ConnectionException` / `TimeoutException` | 0 | No response, or none within `timeout` |

Arguments are checked before any request: an empty, `.` or `..` id, or a reason under 5 characters, throws
`InvalidArgumentException`.

```php
use Clarigoinfotech\Callio\Exception\{ConflictException, RateLimitException};

try {
    $callio->orders->create(['id' => $id, 'customer' => $customer]);
} catch (ConflictException) {
    // already pushed
} catch (RateLimitException $e) {
    usleep((int) (($e->getRetryAfter() ?? 1) * 1e6));   // then retry
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

`Webhook::parseRequest()` checks the `v1` signature in constant time, and rejects a timestamp more than 5
minutes from now (`'tolerance'` option, seconds), so a captured request can't be replayed later. Verify the
**raw body** you received, before parsing it. Each event has a unique `id()`: store the ones you have
handled and drop repeats.

```php
// Laravel (exclude the route from CSRF verification)
use Clarigoinfotech\Callio\Webhook;
use Clarigoinfotech\Callio\Exception\WebhookVerificationException;

Route::post('/callio/webhook', function (Request $request) {
    try {
        $event = Webhook::parseRequest($request->getContent(), $request->headers->all(), config('services.callio.webhook_secret'));
    } catch (WebhookVerificationException) {
        return response()->noContent(401);
    }
    if (Cache::add("callio-event:{$event->id()}", true, now()->addDay()) === false) {
        return response()->noContent();   // already handled
    }
    match ($event->type()) {
        'order.assigned' => Log::info("{$event['order']['id']} → {$event['order']['agent']} by {$event['by']}"),
        'recording.ready' => FetchRecording::dispatch($event['recordingId']),   // metadata only, never audio
        default => null,                                                        // new types may be added
    };
    return response()->noContent();
});
```

Plain PHP: `Webhook::parseRequest(file_get_contents('php://input'), getallheaders(), $secret)`; `$_SERVER`
works as the header array too. A request without `X-Callio-Timestamp` is rejected. While some senders still
use only the legacy header, pass `['allowLegacy' => true]` to fall back to `X-NGX-Signature` (body only, so
such a request could be a replay). `Webhook::verifyRequest()` only checks. The older
`Webhook::verify($body, $signatureHeader, $secret)` / `Webhook::parse()` still work but are deprecated: they
check only the legacy signature.

Event types include `order.created`, `order.assigned`, `order.closed`, `order.reopened` (with `order` and
`by`); `call.*` and `chat.*`; `recording.ready`; `cc.chat-escalated`; `report.snapshot`. Ignore types you
don't handle. Delivery is best-effort with no retries today, so use `events->iterate()` to catch up after
downtime.

## Security

- **Keep the key on your server.** It can read every user, order and recording of your organisation. Never
  put it in a mobile app, a web page or a repository. The app gets a short-lived token from your backend
  instead (`tokens->forUser`).
- **Restrict where the key works.** In the console, *Server API access* (`apiIpAllowlist`) limits your
  organisation's keys to your servers' networks. Calls from other networks get `403`.
- **Rotate keys.** Create the new key, deploy it, then revoke the old one in the console. A revoked key gets
  `401` immediately.
- **The SDK never logs the key.** It is sent only in the `Authorization` header, never in URLs or
  exceptions. `var_dump()`, `print_r()` and `json_encode()` of the client leave it out, `serialize()`
  refuses, and the key parameters are `#[\SensitiveParameter]` so stack traces show it redacted (PHP 8.2+;
  on 8.1 set `zend.exception_ignore_args=On`, the production default). Recording reasons are sent as a
  query parameter, so don't put personal data in them.
- **Redirects are never followed** (`CURLOPT_FOLLOWLOCATION` off, http/https only). A 3xx throws
  `RedirectException`, so the key can't be carried to another host.
- **HTTPS only.** `http://` is refused unless you pass `allowInsecure: true`, meant for a local stack.
- **Ids are checked.** An empty, `.` or `..` id or username is rejected before any request is built.

## Development

```sh
composer install
composer test                                   # unit tests (scripted transport + a php -S loopback server)
CALLIO_ADMIN_PASS=… composer test:integration    # against a running stack
```

No PHP? Use Docker: `docker run --rm -v "$PWD":/app -w /app composer:2 install`, then
`docker run --rm -v "$PWD":/app -w /app php:8.3-cli vendor/bin/phpunit --testsuite unit` (for the
integration suite add `-e CALLIO_ADMIN_PASS=… -e CALLIO_URL=http://host.docker.internal:8080`). Tested on
PHP 8.1 and 8.3.

The integration test signs in to the admin API (`CALLIO_URL`, default `http://localhost:8080`;
`CALLIO_ADMIN_USER`, default `admin`). It creates a temporary API key for `CALLIO_TENANT` (default `lab`),
runs every resource, and then deletes what it created and revokes the key. Set `CALLIO_IT_AUDIO=1` to also
download one recording.

Versioning: the package starts at 0.1.0 (`Version::VERSION`) and follows the tenant API (`/api/v1`),
independently of the mobile SDKs.
