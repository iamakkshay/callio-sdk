// Unit tests against a mocked fetch: no network. Run with `npm test` (builds first).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { inspect } from 'node:util';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  Callio, VERSION, CallioError, ValidationError, AuthenticationError, PermissionDeniedError, NotFoundError, ConflictError,
  GoneError, RateLimitError, ServerError, ConnectionError, TimeoutError, verifyWebhook, parseWebhook, signWebhook,
  WebhookVerificationError, isOrderEvent, signWebhookV1,
} from '../dist/index.js';
import http from 'node:http';

const KEY = 'cio_abc123_s3cret-value';
const json = (status, body, headers = {}) => new Response(body === undefined ? null : JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } });

// A scripted fetch: each call takes the next response (or a function of the request).
function mock(...responses) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, ...init, json: init.body ? JSON.parse(init.body) : undefined });
    const r = responses.shift();
    if (!r) throw new Error('unexpected request ' + url);
    return typeof r === 'function' ? r(url, init) : r;
  };
  return { fetch, calls };
}
function client(m, opts = {}) {
  const c = new Callio({ apiKey: KEY, baseUrl: 'https://api.example.test/', fetch: m.fetch, ...opts });
  c.http.backoff = () => 0;
  return c;
}

test('sends the key as a Bearer token, JSON body, and a versioned User-Agent', async () => {
  const m = mock(json(201, { user: { username: 'u1', extension: '1001' } }));
  const u = await client(m).users.create({ username: 'u1', displayName: 'U One', userType: 'customer' });
  assert.equal(u.extension, '1001');
  const c = m.calls[0];
  assert.equal(c.url, 'https://api.example.test/api/v1/users');
  assert.equal(c.method, 'POST');
  assert.equal(c.headers.Authorization, `Bearer ${KEY}`);
  assert.equal(c.headers['Content-Type'], 'application/json');
  assert.match(c.headers['User-Agent'], new RegExp(`^callio-server-node/${VERSION.replace(/\./g, '\\.')} node/`));
  assert.deepEqual(c.json, { username: 'u1', displayName: 'U One', userType: 'customer' });
});

test('query strings skip empty values, join arrays, and path segments are encoded', async () => {
  const m = mock(json(200, { users: [] }), json(200, { events: [], next: 5 }), json(200, { user: {} }), json(200, { recordings: [] }));
  const c = client(m);
  await c.users.list({ q: 'sa ra', type: 'agent', status: undefined });
  await c.events.list({ after: 5, types: ['call.', 'chat.'] });
  await c.users.get('a/b@c');
  await c.recordings.list({ from: new Date('2026-01-01T00:00:00Z'), minDuration: 10 });
  assert.equal(m.calls[0].url, 'https://api.example.test/api/v1/users?q=sa+ra&type=agent');
  assert.equal(m.calls[1].url, 'https://api.example.test/api/v1/events?after=5&types=call.%2Cchat.');
  assert.equal(m.calls[2].url, 'https://api.example.test/api/v1/users/a%2Fb%40c');
  assert.equal(m.calls[3].url, 'https://api.example.test/api/v1/recordings?from=2026-01-01T00%3A00%3A00.000Z&minDuration=10');
});

test('maps statuses to typed errors with the server message', async () => {
  const cases = [[400, ValidationError], [401, AuthenticationError], [403, PermissionDeniedError], [404, NotFoundError],
    [409, ConflictError], [410, GoneError], [500, ServerError], [418, CallioError]];
  for (const [status, Cls] of cases) {
    const m = mock(json(status, { error: `reason ${status}` }));
    await assert.rejects(client(m, { maxRetries: 0 }).orders.get('X'), (e) => {
      assert.ok(e instanceof Cls, `${status} → ${e.constructor.name}`);
      assert.ok(e instanceof CallioError);
      assert.equal(e.status, status);
      assert.equal(e.message, `reason ${status}`);
      assert.equal(e.request, 'GET /api/v1/orders/X');
      assert.ok(!JSON.stringify(e).includes(KEY) && !String(e.stack).includes(KEY));
      return true;
    });
  }
});

test('403 from the IP allow-list is a PermissionDeniedError', async () => {
  const m = mock(json(403, { error: "this network (203.0.113.9) is not allowed to use this organisation's API" }));
  await assert.rejects(client(m).users.list(), (e) => e instanceof PermissionDeniedError && /not allowed/.test(e.message));
});

test('GET retries on 429 (honouring Retry-After) and 5xx, then succeeds', async () => {
  const m = mock(json(429, { error: 'slow down' }, { 'retry-after': '2' }), json(503, { error: 'busy' }), json(200, { orders: [{ id: 'A' }] }));
  const c = client(m);
  const waits = [];
  c.http.backoff = (attempt, ra) => { waits.push([attempt, ra]); return 0; };
  const orders = await c.orders.list();
  assert.equal(orders[0].id, 'A');
  assert.equal(m.calls.length, 3);
  assert.deepEqual(waits, [[0, 2], [1, undefined]]);
});

test('gives up after maxRetries with a RateLimitError carrying retryAfter', async () => {
  const m = mock(json(429, { error: 'a' }, { 'retry-after': '7' }), json(429, { error: 'b' }, { 'retry-after': '7' }));
  await assert.rejects(client(m, { maxRetries: 1 }).cdr.list(), (e) => e instanceof RateLimitError && e.retryAfter === 7 && e.status === 429);
  assert.equal(m.calls.length, 2);
});

test('POST and PATCH are never retried', async () => {
  const m1 = mock(json(503, { error: 'busy' }));
  await assert.rejects(client(m1).orders.create({ id: 'O1', customer: 'c' }), ServerError);
  assert.equal(m1.calls.length, 1);
  const m2 = mock(json(429, { error: 'slow' }, { 'retry-after': '1' }));
  await assert.rejects(client(m2).orders.close('O1'), RateLimitError);
  assert.equal(m2.calls.length, 1);
});

test('network errors are retried for GET and surface as ConnectionError', async () => {
  const boom = () => { throw new TypeError('fetch failed'); };
  const m = mock(boom, boom, boom);
  await assert.rejects(client(m).groups.list(), (e) => e instanceof ConnectionError && e.status === 0 && !e.message.includes(KEY));
  assert.equal(m.calls.length, 3);
});

test('times out with TimeoutError', async () => {
  const hang = (url, init) => new Promise((_, rej) => init.signal.addEventListener('abort', () => rej(new Error('aborted'))));
  const m = mock(hang);
  await assert.rejects(client(m, { timeout: 20, maxRetries: 0 }).users.get('x'), TimeoutError);
});

test('tokens.forUser creates the user, then issues a token', async () => {
  const m = mock(json(201, { user: { username: 'c1' } }), json(200, { token: 'jwt', userType: 'customer', expiresAt: 'later' }));
  const t = await client(m).tokens.forUser('c1', { displayName: 'C', userType: 'customer', ttlSec: 600 });
  assert.deepEqual(t, { token: 'jwt', userType: 'customer', expiresAt: 'later', created: true });
  assert.deepEqual(m.calls[0].json, { username: 'c1', displayName: 'C', userType: 'customer' });
  assert.deepEqual(m.calls[1].json, { username: 'c1', ttlSec: 600 });
});

test('tokens.forUser treats 409 as "already exists"', async () => {
  const m = mock(json(409, { error: 'user exists' }), json(200, { token: 'jwt', userType: 'agent', expiresAt: 'x' }));
  const t = await client(m).tokens.forUser('a1', { userType: 'agent' });
  assert.equal(t.created, false);
  assert.equal(t.token, 'jwt');
});

test('tokens.forUser propagates other errors (quota)', async () => {
  const m = mock(json(403, { error: 'seat quota reached' }));
  await assert.rejects(client(m).tokens.forUser('a1'), PermissionDeniedError);
  assert.equal(m.calls.length, 1);
});

test('order helpers send the right patch', async () => {
  const o = { order: { id: 'O1' } };
  const m = mock(json(200, o), json(200, o), json(200, o), json(200, o));
  const c = client(m);
  await c.orders.assign('O1', 'drv'); await c.orders.assign('O1', null); await c.orders.close('O1'); await c.orders.reopen('O1');
  assert.deepEqual(m.calls.map((x) => [x.method, x.json]), [['PATCH', { agent: 'drv' }], ['PATCH', { agent: null }], ['PATCH', { status: 'closed' }], ['PATCH', { status: 'active' }]]);
});

test('users.delete sends the reason in the body', async () => {
  const m = mock(json(200, { ok: true, alias: 'erased-1', removed: {}, recordingsKeptOnLegalHold: [] }));
  const r = await client(m).users.delete('u1', { reason: 'customer asked' });
  assert.equal(r.alias, 'erased-1');
  assert.equal(m.calls[0].method, 'DELETE');
  assert.deepEqual(m.calls[0].json, { reason: 'customer asked' });
});

test('recording audio streams with the reason, and download writes the file', async () => {
  const bytes = new Uint8Array([79, 103, 103, 83, 1, 2, 3]);
  const audio = () => new Response(new Blob([bytes]).stream(), { status: 200, headers: { 'content-type': 'audio/ogg', 'content-length': String(bytes.length) } });
  const m = mock(audio, audio);
  const c = client(m);
  const a = await c.recordings.audio('rec-1', { reason: 'QA review — طلب' });
  assert.equal(a.contentType, 'audio/ogg');
  assert.equal(a.contentLength, 7);
  assert.deepEqual(new Uint8Array(await new Response(a.body).arrayBuffer()), bytes);
  assert.equal(new URL(m.calls[0].url).searchParams.get('reason'), 'QA review — طلب');
  const file = join(mkdtempSync(join(tmpdir(), 'callio-')), 'a.ogg');
  assert.equal(await c.recordings.download('rec-1', file, { reason: 'dispute 123' }), 7);
  assert.deepEqual(new Uint8Array(readFileSync(file)), bytes);
});

test('recording audio requires a reason client-side and maps 410', async () => {
  const c = client(mock(json(410, { error: 'this recording was deleted' })));
  await assert.rejects(c.recordings.audio('r', { reason: 'no' }), TypeError);
  await assert.rejects(c.recordings.audio('r', { reason: 'audit check' }), GoneError);
});

test('events.iterate pages until caught up', async () => {
  const m = mock(json(200, { events: [{ id: 1 }, { id: 2 }], next: 2 }), json(200, { events: [{ id: 3 }], next: 3 }), json(200, { events: [], next: 3 }));
  const ids = [];
  for await (const e of client(m).events.iterate({ limit: 2 })) ids.push(e.id);
  assert.deepEqual(ids, [1, 2, 3]);
  assert.deepEqual(m.calls.map((x) => new URL(x.url).searchParams.get('after')), ['0', '2', '3']);
});

test('the API key never shows in inspect, JSON or errors', async () => {
  const c = client(mock());
  assert.ok(!inspect(c, { depth: 10 }).includes(KEY));
  assert.ok(!JSON.stringify(c).includes(KEY));
  assert.ok(!inspect(c.http, { depth: 10, showHidden: true }).includes(KEY));
});

test('constructor validates options and reads env vars', () => {
  const save = { ...process.env };
  delete process.env.CALLIO_API_KEY; delete process.env.CALLIO_BASE_URL;
  assert.throws(() => new Callio({ baseUrl: 'https://x' }), /apiKey is required/);
  assert.throws(() => new Callio({ apiKey: KEY }), /baseUrl is required/);
  assert.throws(() => new Callio({ apiKey: KEY, baseUrl: 'api.example.sa' }), /https/);
  process.env.CALLIO_API_KEY = KEY; process.env.CALLIO_BASE_URL = 'https://env.example/';
  assert.equal(new Callio().http.baseUrl, 'https://env.example');
  Object.assign(process.env, save);
});

// ---- webhooks ----
const SECRET = 'whsec_test';
const body = JSON.stringify({ tenantId: 'lab', type: 'order.assigned', order: { id: 'O1', agent: 'drv' }, by: 'apikey:abc', at: '2026-01-01T00:00:00Z' });
const sig = 'sha256=' + createHmac('sha256', SECRET).update(body).digest('hex');

test('verifyWebhook accepts the platform signature for string, Buffer and Uint8Array bodies', () => {
  assert.equal(signWebhook(body, SECRET), sig);
  assert.ok(verifyWebhook(body, sig, SECRET));
  assert.ok(verifyWebhook(Buffer.from(body), sig, SECRET));
  assert.ok(verifyWebhook(new TextEncoder().encode(body), sig.toUpperCase().replace('SHA256=', 'sha256='), SECRET));
  assert.ok(verifyWebhook(body, [sig], SECRET));
});

test('verifyWebhook rejects tampering, wrong secret, and malformed headers', () => {
  assert.equal(verifyWebhook(body + ' ', sig, SECRET), false);
  assert.equal(verifyWebhook(body, sig, 'other'), false);
  for (const h of [undefined, null, '', 'sha256=', 'sha256=zz', sig.slice(7), 'sha1=' + sig.slice(7), sig + '00']) assert.equal(verifyWebhook(body, h, SECRET), false);
  assert.throws(() => verifyWebhook(body, sig, ''), TypeError);
});

test('parseWebhook returns a typed event or throws', () => {
  const ev = parseWebhook(body, sig, SECRET);
  assert.ok(isOrderEvent(ev));
  assert.equal(ev.order.agent, 'drv');
  assert.throws(() => parseWebhook(body, 'sha256=' + '0'.repeat(64), SECRET), WebhookVerificationError);
  const notJson = 'nope';
  assert.throws(() => parseWebhook(notJson, signWebhook(notJson, SECRET), SECRET), WebhookVerificationError);
});

// ---- signed + timestamped webhooks (v1) ----
const NOW = 1_800_000_000;
const v1Body = JSON.stringify({ id: 'evt_123', tenantId: 'lab', type: 'order.created', order: { id: 'O2' }, by: 'admin:a', at: '2026-01-01T00:00:00Z' });
const v1Headers = (ts = NOW, b = v1Body, secret = SECRET) => ({
  'x-callio-timestamp': String(ts), 'x-callio-signature': signWebhookV1(b, secret, ts), 'x-ngx-signature': signWebhook(b, secret),
});

test('v1: verifies ts.body with headers from an object, a Headers instance or a Map, and exposes the event id', () => {
  const v = 'v1=' + createHmac('sha256', SECRET).update(`${NOW}.${v1Body}`).digest('hex');
  assert.equal(signWebhookV1(v1Body, SECRET, NOW), v);
  assert.ok(verifyWebhook(v1Body, v1Headers(), SECRET, { now: NOW }));
  assert.ok(verifyWebhook(v1Body, new Headers(v1Headers()), SECRET, { now: NOW + 299 }));
  const mixed = { 'X-Callio-Timestamp': String(NOW), 'X-Callio-Signature': `v1=${'0'.repeat(64)}, ${v}` };
  assert.ok(verifyWebhook(v1Body, mixed, SECRET, { now: NOW }), 'case-insensitive names, several v1 entries');
  assert.ok(verifyWebhook(v1Body, new Map(Object.entries(mixed)), SECRET, { now: NOW }));
  const ev = parseWebhook(Buffer.from(v1Body), v1Headers(), SECRET, { now: NOW });
  assert.equal(ev.id, 'evt_123');
});

test('v1: rejects stale or future timestamps (default 300 s, configurable), tampering and a missing timestamp', () => {
  assert.equal(verifyWebhook(v1Body, v1Headers(NOW - 301), SECRET, { now: NOW }), false);
  assert.equal(verifyWebhook(v1Body, v1Headers(NOW + 301), SECRET, { now: NOW }), false);
  assert.ok(verifyWebhook(v1Body, v1Headers(NOW - 500), SECRET, { now: NOW, toleranceSec: 600 }));
  assert.equal(verifyWebhook(v1Body, v1Headers(NOW - 61), SECRET, { now: NOW, toleranceSec: 60 }), false);
  assert.equal(verifyWebhook(v1Body + ' ', v1Headers(), SECRET, { now: NOW }), false);
  assert.equal(verifyWebhook(v1Body, v1Headers(NOW, v1Body, 'other'), SECRET, { now: NOW }), false);
  // replay with a fresh timestamp but the old signature
  assert.equal(verifyWebhook(v1Body, { ...v1Headers(NOW - 1000), 'x-callio-timestamp': String(NOW) }, SECRET, { now: NOW }), false);
  for (const ts of ['', 'abc', '1e9', '-5']) assert.equal(verifyWebhook(v1Body, { ...v1Headers(), 'x-callio-timestamp': ts }, SECRET, { now: NOW }), false, ts);
  // only the legacy header: rejected unless allowLegacy
  const legacyOnly = { 'x-ngx-signature': signWebhook(v1Body, SECRET) };
  assert.equal(verifyWebhook(v1Body, legacyOnly, SECRET), false);
  assert.throws(() => parseWebhook(v1Body, legacyOnly, SECRET), /X-Callio-Timestamp/);
  assert.ok(verifyWebhook(v1Body, legacyOnly, SECRET, { allowLegacy: true }));
  assert.equal(parseWebhook(v1Body, legacyOnly, SECRET, { allowLegacy: true }).id, 'evt_123');
  assert.equal(verifyWebhook(v1Body, { 'x-ngx-signature': sig }, SECRET, { allowLegacy: true }), false);
  // a timestamp present always means v1 is required, even with allowLegacy
  assert.equal(verifyWebhook(v1Body, { ...legacyOnly, 'x-callio-timestamp': String(NOW) }, SECRET, { now: NOW, allowLegacy: true }), false);
  assert.throws(() => parseWebhook(v1Body, v1Headers(NOW - 301), SECRET, { now: NOW }), (e) => e instanceof WebhookVerificationError && e.status === 401 && /tolerance/.test(e.message));
});

test('never follows a redirect (the API key must not reach another host)', async () => {
  const m = mock((url, init) => { assert.equal(init.redirect, 'manual'); return new Response(null, { status: 302, headers: { location: 'https://evil.example/x' } }); });
  await assert.rejects(client(m).users.list(), (e) => e instanceof CallioError && e.status === 302 && /redirect/.test(e.message) && !e.message.includes(KEY));
  assert.equal(m.calls.length, 1);
  // and with the real global fetch against real servers
  let seen = 'not contacted';
  const b = http.createServer((q, r) => { seen = q.headers.authorization; r.setHeader('content-type', 'application/json'); r.end('{"users":[]}'); }).listen(0);
  await new Promise((r) => b.on('listening', r));
  const a = http.createServer((q, r) => { r.writeHead(302, { location: `http://localhost:${b.address().port}/x` }); r.end(); }).listen(0);
  await new Promise((r) => a.on('listening', r));
  try {
    const c = new Callio({ apiKey: KEY, baseUrl: `http://127.0.0.1:${a.address().port}`, allowInsecure: true, maxRetries: 0 });
    await assert.rejects(c.users.list(), /redirect/);
    assert.equal(seen, 'not contacted');
  } finally { a.close(); b.close(); }
});

test('baseUrl must be https unless allowInsecure is set', () => {
  assert.throws(() => new Callio({ apiKey: KEY, baseUrl: 'http://api.example.sa' }), /allowInsecure/);
  assert.throws(() => new Callio({ apiKey: KEY, baseUrl: 'ftp://api.example.sa' }), /https/);
  assert.throws(() => new Callio({ apiKey: KEY, baseUrl: 'ftp://api.example.sa', allowInsecure: true }), /https/);
  assert.equal(new Callio({ apiKey: KEY, baseUrl: 'http://localhost:8080/', allowInsecure: true }).http.baseUrl, 'http://localhost:8080');
});

test('path segments "." and ".." are rejected before any request', async () => {
  const m = mock();
  const c = client(m);
  for (const s of ['.', '..']) {
    await assert.rejects(c.users.get(s), ValidationError);
    await assert.rejects(c.users.signOut(s), ValidationError);
    await assert.rejects(c.orders.get(s), ValidationError);
  }
  await assert.rejects(c.users.get(''), TypeError);
  assert.equal(m.calls.length, 0);
});

test('VERSION matches package.json', async () => {
  const { readFile } = await import('node:fs/promises');
  assert.equal(VERSION, JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8')).version);
});
