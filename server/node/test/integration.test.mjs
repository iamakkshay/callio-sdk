// Integration test against a running Callio stack. It signs in to the admin API, creates a temporary API
// key for the tenant, exercises the SDK, and cleans up everything it made (users, order, group, the key).
// Nothing secret lives in this file; pass it in the environment:
//
//   CALLIO_ADMIN_PASS=… [CALLIO_ADMIN_USER=admin] [CALLIO_URL=http://localhost:8080] [CALLIO_TENANT=lab] \
//     npm run test:integration
//
// CALLIO_IT_AUDIO=1 also downloads one recording (that read is written to the recording's access trail).
//
// Skipped when CALLIO_ADMIN_PASS is not set.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { Callio, ConflictError, NotFoundError, ValidationError, AuthenticationError } from '../dist/index.js';

const URL_ = (process.env.CALLIO_URL || 'http://localhost:8080').replace(/\/$/, '');
const TENANT = process.env.CALLIO_TENANT || 'lab';
const PASS = process.env.CALLIO_ADMIN_PASS;
const skip = !PASS && 'set CALLIO_ADMIN_PASS (and optionally CALLIO_ADMIN_USER, CALLIO_URL, CALLIO_TENANT)';

const run = Date.now().toString(36);
const CUST = `sdk-it-node-c-${run}`, AGENT = `sdk-it-node-a-${run}`, ORDER = `SDK-IT-NODE-${run}`, GROUP = `sdk-it-node-g-${run}`;
let admin, key, callio;
const created = { users: [], group: null, order: null };

async function adminReq(method, path, body) {
  const r = await fetch(`${URL_}${path}`, { method, headers: { 'content-type': 'application/json', ...(admin ? { authorization: `Bearer ${admin}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`${method} ${path} → ${r.status} ${j.error || ''}`);
  return j;
}

before(async () => {
  if (skip) return;
  admin = (await adminReq('POST', '/api/admin/login', { username: process.env.CALLIO_ADMIN_USER || 'admin', password: PASS })).token;
  assert.ok(admin, 'admin login (MFA-enabled admins are not supported by this test)');
  key = (await adminReq('POST', `/api/admin/tenants/${TENANT}/api-keys`, { name: `sdk-it-node-${run}` })).key;
  callio = new Callio({ apiKey: key.key, baseUrl: URL_, userAgent: 'callio-it', allowInsecure: URL_.startsWith('http://') });
});

after(async () => {
  if (skip || !callio) return;
  if (created.group) await callio.groups.delete(created.group).catch(() => {});
  if (created.order) await callio.orders.close(created.order).catch(() => {});   // orders can't be deleted; erasing the users pseudonymises it
  for (const u of created.users) await callio.users.delete(u, { reason: 'SDK integration test cleanup' }).catch(() => {});
  if (key) await adminReq('DELETE', `/api/admin/tenants/${TENANT}/api-keys/${key.id}`);
  // The revoked key no longer works.
  await assert.rejects(callio.users.list({ limit: 1 }), AuthenticationError);
});

test('users: create, conflict, get, update, list, token, sign-out, export', { skip }, async () => {
  const c = await callio.users.create({ username: CUST, displayName: 'SDK IT Customer', userType: 'customer' });
  created.users.push(CUST);
  assert.equal(c.username, CUST);
  assert.equal(c.userType, 'customer');
  assert.ok(c.extension);
  assert.ok(c.initialPassword, 'a random password is returned once');
  await assert.rejects(callio.users.create({ username: CUST }), ConflictError);
  await assert.rejects(callio.users.create({ username: 'bad name!' }), ValidationError);
  await assert.rejects(callio.users.get(`${CUST}-missing`), NotFoundError);

  assert.equal((await callio.users.get(CUST)).displayName, 'SDK IT Customer');
  const u = await callio.users.update(CUST, { displayName: 'SDK IT Renamed', segment: 'sdk-it' });
  assert.equal(u.displayName, 'SDK IT Renamed');
  assert.equal(u.segment, 'sdk-it');
  assert.ok((await callio.users.list({ q: CUST })).some((x) => x.username === CUST));

  const t = await callio.tokens.create({ username: CUST, ttlSec: 120 });
  assert.equal(t.token.split('.').length, 3);
  assert.equal(t.userType, 'customer');
  assert.ok(Date.parse(t.expiresAt) > Date.now());
  assert.deepEqual(await callio.users.signOut(CUST), { ok: true });
  const ex = await callio.users.export(CUST);
  assert.ok(ex.exportedAt);
});

test('tokens.forUser: creates when missing, reuses when present', { skip }, async () => {
  const first = await callio.tokens.forUser(AGENT, { displayName: 'SDK IT Agent', userType: 'agent', ttlSec: 60 });
  created.users.push(AGENT);
  assert.equal(first.created, true);
  assert.equal(first.userType, 'agent');
  const again = await callio.tokens.forUser(AGENT, { userType: 'agent' });
  assert.equal(again.created, false);
  assert.ok(again.token);
  await callio.users.disable(AGENT);
  await assert.rejects(callio.tokens.create({ username: AGENT }), (e) => e.status === 403);
  await callio.users.enable(AGENT);
});

test('orders: create, conflict, get, list, assign, close, reopen; events see it', { skip }, async () => {
  const before = (await callio.events.list({ after: 0, limit: 1 })).next;
  await assert.rejects(callio.orders.create({ id: ORDER, customer: AGENT }), ValidationError);   // wrong user type
  const o = await callio.orders.create({ id: ORDER, customer: CUST, label: 'SDK integration test' });
  created.order = ORDER;
  assert.equal(o.status, 'active');
  assert.equal(o.agent, null);
  await assert.rejects(callio.orders.create({ id: ORDER, customer: CUST }), ConflictError);
  assert.equal((await callio.orders.get(ORDER)).label, 'SDK integration test');
  assert.ok((await callio.orders.list({ user: CUST })).some((x) => x.id === ORDER));
  assert.equal((await callio.orders.assign(ORDER, AGENT)).agent, AGENT);
  assert.equal((await callio.orders.close(ORDER)).status, 'closed');
  assert.equal((await callio.orders.reopen(ORDER)).status, 'active');
  assert.equal((await callio.orders.update(ORDER, { status: 'closed' })).status, 'closed');
  await assert.rejects(callio.orders.get(`${ORDER}-nope`), NotFoundError);

  // The event feed (polled from just before our changes) carries the order events.
  const seen = [];
  for await (const e of callio.events.iterate({ after: Math.max(0, before - 1), types: ['order.'], limit: 100 })) if (e.orderId === ORDER) seen.push(e.type);
  for (const t of ['order.created', 'order.assigned', 'order.closed', 'order.reopened']) assert.ok(seen.includes(t), `${t} in ${seen}`);
});

test('groups: create, get, update, list, delete', { skip }, async () => {
  const g = await callio.groups.create({ id: GROUP, name: 'SDK IT group', members: [CUST, AGENT] });
  created.group = GROUP;
  assert.equal(g.members.length, 2);
  assert.equal((await callio.groups.get(GROUP)).name, 'SDK IT group');
  const u = await callio.groups.update(GROUP, { name: 'SDK IT renamed', remove: [AGENT] });
  assert.equal(u.name, 'SDK IT renamed');
  assert.deepEqual(u.members.map((m) => m.username), [CUST]);
  assert.ok((await callio.groups.list()).some((x) => x.id === GROUP));
  assert.deepEqual(await callio.groups.delete(GROUP), { ok: true });
  created.group = null;
  await assert.rejects(callio.groups.get(GROUP), NotFoundError);
});

test('recordings and cdr: list, get, missing', { skip }, async () => {
  const recs = await callio.recordings.list({ limit: 5 });
  assert.ok(Array.isArray(recs));
  if (recs[0]) assert.equal((await callio.recordings.get(recs[0].id)).id, recs[0].id);
  // Downloading writes to the recording's access trail, so it is opt-in: CALLIO_IT_AUDIO=1.
  if (recs[0] && process.env.CALLIO_IT_AUDIO === '1') {
    const a = await callio.recordings.audio(recs[0].id, { reason: 'SDK integration test' });
    const buf = new Uint8Array(await new Response(a.body).arrayBuffer());
    assert.equal(buf.length, recs[0].bytes);
    assert.equal(new TextDecoder().decode(buf.slice(0, 4)), 'OggS');
  }
  await assert.rejects(callio.recordings.get('no-such-recording'), NotFoundError);
  await assert.rejects(callio.recordings.audio('no-such-recording', { reason: 'SDK integration test' }), NotFoundError);
  const cdr = await callio.cdr.list({ days: 30 });
  assert.equal(cdr.days, 30);
  assert.ok(Array.isArray(cdr.calls));
});

test('users.delete: PDPL erasure', { skip }, async () => {
  const r = await callio.users.delete(AGENT, { reason: 'SDK integration test cleanup' });
  assert.equal(r.ok, true);
  assert.match(r.alias, /^erased-/);
  created.users = created.users.filter((u) => u !== AGENT);
  await assert.rejects(callio.users.get(AGENT), NotFoundError);
});
