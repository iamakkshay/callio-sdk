// Webhook verification. Callio POSTs JSON events to the organisation's webhook URL with:
//   X-Callio-Timestamp: <unix seconds>
//   X-Callio-Signature: v1=<hex HMAC-SHA256(secret, `${timestamp}.${rawBody}`)>
//   X-NGX-Signature:    sha256=<hex HMAC-SHA256(secret, rawBody)>   (legacy, body only)
// and a unique `id` per delivery event in the body. Verify the v1 signature (it binds the timestamp, so an
// old delivery can't be replayed outside the tolerance window) and de-duplicate on `id` inside the window.
// Verify against the exact bytes received: re-serialising parsed JSON changes them.
import { createHmac, timingSafeEqual } from 'node:crypto';
import type { Order } from './types.js';
import { CallioError } from './errors.js';

/** The legacy, body-only signature header. */
export const SIGNATURE_HEADER = 'x-ngx-signature';
export const TIMESTAMP_HEADER = 'x-callio-timestamp';
export const SIGNATURE_V1_HEADER = 'x-callio-signature';
/** Default accepted clock difference, in seconds. */
export const DEFAULT_TOLERANCE_SEC = 300;

export class WebhookVerificationError extends CallioError {}

type Raw = string | Uint8Array | ArrayBuffer;
const bytes = (b: Raw): Buffer =>
  typeof b === 'string' ? Buffer.from(b, 'utf8') : b instanceof ArrayBuffer ? Buffer.from(new Uint8Array(b)) : Buffer.from(b.buffer, b.byteOffset, b.byteLength);

type HeaderValue = string | string[] | null | undefined;
/**
 * The request headers: a fetch `Headers`, a `Map`, or a plain object such as Express/Node `req.headers`
 * (names are matched case-insensitively).
 */
export type WebhookHeaders = { get(name: string): string | null | undefined } | Record<string, HeaderValue>;

export interface VerifyWebhookOptions {
  /** Accepted difference between the X-Callio-Timestamp and now, in seconds (default 300). */
  toleranceSec?: number;
  /**
   * Accept a delivery without X-Callio-Timestamp by checking only the legacy, body-only X-NGX-Signature.
   * That has no replay protection; use it only while migrating from an older platform version.
   */
  allowLegacy?: boolean;
  /** The current time in unix seconds (tests). */
  now?: number;
}

/** The `sha256=<hex>` legacy value Callio sends for this body. */
export function signWebhook(rawBody: Raw, secret: string): string {
  return `sha256=${createHmac('sha256', secret).update(bytes(rawBody)).digest('hex')}`;
}

/** The `v1=<hex>` X-Callio-Signature value for this timestamp (unix seconds) and body. */
export function signWebhookV1(rawBody: Raw, secret: string, timestamp: number | string): string {
  return `v1=${createHmac('sha256', secret).update(`${timestamp}.`).update(bytes(rawBody)).digest('hex')}`;
}

const first = (v: HeaderValue): string | undefined => {
  const x = Array.isArray(v) ? v[0] : v;
  return x === null || x === undefined ? undefined : String(x);
};

function header(h: WebhookHeaders, name: string): string | undefined {
  if (typeof (h as { get?: unknown }).get === 'function') {
    const v = (h as { get(n: string): unknown }).get(name);
    if (v !== null && v !== undefined) return first(v as HeaderValue);
    if (h instanceof Map) {
      for (const [k, val] of h as Map<string, HeaderValue>) if (String(k).toLowerCase() === name) return first(val);
    }
    return undefined;
  }
  const rec = h as Record<string, HeaderValue>;
  if (rec[name] !== undefined) return first(rec[name]);
  for (const k of Object.keys(rec)) if (k.toLowerCase() === name) return first(rec[k]);
  return undefined;
}

const eqHex = (hex: string, want: Buffer): boolean => {
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) return false;
  const got = Buffer.from(hex.toLowerCase(), 'hex');
  return got.length === want.length && timingSafeEqual(got, want);
};

function checkLegacy(rawBody: Raw, signatureHeader: HeaderValue, secret: string): boolean {
  const m = /^sha256=([0-9a-fA-F]{64})$/.exec(String(first(signatureHeader) ?? '').trim());
  if (!m || !m[1]) return false;
  return eqHex(m[1], createHmac('sha256', secret).update(bytes(rawBody)).digest());
}

/** null when the delivery is authentic and fresh, otherwise the reason it is not. */
function check(rawBody: Raw, headers: WebhookHeaders, secret: string, opts: VerifyWebhookOptions): string | null {
  const ts = header(headers, TIMESTAMP_HEADER)?.trim();
  if (!ts) {
    if (!opts.allowLegacy) return 'missing X-Callio-Timestamp (pass { allowLegacy: true } to accept body-only signatures)';
    return checkLegacy(rawBody, header(headers, SIGNATURE_HEADER), secret) ? null : 'bad or missing X-NGX-Signature';
  }
  if (!/^\d{1,15}$/.test(ts)) return 'malformed X-Callio-Timestamp';
  const tolerance = opts.toleranceSec ?? DEFAULT_TOLERANCE_SEC;
  if (!(tolerance >= 0)) throw new TypeError('Callio: toleranceSec must be a non-negative number');
  const now = opts.now ?? Math.floor(Date.now() / 1000);
  if (Math.abs(now - Number(ts)) > tolerance) return 'X-Callio-Timestamp is outside the tolerance window';
  const want = createHmac('sha256', secret).update(`${ts}.`).update(bytes(rawBody)).digest();
  // Several `v1=` entries (comma separated) are allowed, e.g. while a secret is being rotated.
  const sigs = String(header(headers, SIGNATURE_V1_HEADER) ?? '').split(',').map((p) => p.trim());
  let ok = false;
  for (const p of sigs) if (p.startsWith('v1=') && eqHex(p.slice(3), want)) ok = true;
  return ok ? null : 'bad or missing X-Callio-Signature';
}

const isHeaders = (x: unknown): x is WebhookHeaders => !!x && typeof x === 'object' && !Array.isArray(x);

/**
 * Verify a delivery. Pass the request headers (recommended):
 *
 *     verifyWebhook(rawBody, req.headers, secret)            // v1 signature + 300 s timestamp tolerance
 *     verifyWebhook(rawBody, req.headers, secret, { toleranceSec: 120 })
 *
 * A delivery without X-Callio-Timestamp is rejected unless `{ allowLegacy: true }` is passed.
 * Constant-time comparison; false (never throws) for missing or malformed headers.
 *
 * @deprecated form: `verifyWebhook(rawBody, signatureHeader, secret)` with the X-NGX-Signature value only
 * checks the legacy body signature, which can be replayed. Pass the headers instead.
 */
export function verifyWebhook(rawBody: Raw, headers: WebhookHeaders, secret: string, options?: VerifyWebhookOptions): boolean;
/** @deprecated Pass the request headers object instead: the body-only signature has no replay protection. */
export function verifyWebhook(rawBody: Raw, signatureHeader: string | string[] | null | undefined, secret: string): boolean;
export function verifyWebhook(rawBody: Raw, headersOrSignature: WebhookHeaders | HeaderValue, secret: string, options: VerifyWebhookOptions = {}): boolean {
  if (!secret) throw new TypeError('Callio: the webhook secret is required');
  if (isHeaders(headersOrSignature)) return check(rawBody, headersOrSignature, secret, options) === null;
  return checkLegacy(rawBody, headersOrSignature, secret);
}

interface Base {
  /** Unique per delivery event: store it and drop a repeat (same `id`) inside the tolerance window. */
  id?: string;
  tenantId: string;
  at: string;
}
export interface OrderEvent extends Base { type: 'order.created' | 'order.assigned' | 'order.closed' | 'order.reopened'; order: Order; /** `apikey:<id>` or `admin:<username>`. */ by: string }
export interface CallOrChatEvent extends Base { type: `call.${string}` | `chat.${string}` | `location.${string}`; callId: string | null; from: string; to: string | null; payload: Record<string, unknown> | null }
export interface RecordingReadyEvent extends Base { type: 'recording.ready'; callId: string | null; recordingId: string; durationSec: number; retainUntil: string | null }
export interface ChatEscalatedEvent extends Base { type: 'cc.chat-escalated'; interaction: string; user: string; entryPoint: string; transcriptUrl: string; location?: unknown }
export interface ReportSnapshotEvent extends Base { type: 'report.snapshot'; windowDays: number; kpis: Record<string, unknown>; series: unknown; generatedAt: string }
/** Any other event type the platform adds later. */
export interface UnknownEvent extends Base { type: string; [k: string]: unknown }

export type WebhookEvent = OrderEvent | RecordingReadyEvent | ChatEscalatedEvent | ReportSnapshotEvent | CallOrChatEvent | UnknownEvent;

/**
 * Verify the delivery and parse the event. Throws WebhookVerificationError (status 401) on a bad, stale or
 * missing signature and (status 400) on a body that is not an event. Same arguments as verifyWebhook.
 * The event's `id` is unique per delivery: use it to drop repeats.
 */
export function parseWebhook(rawBody: Raw, headers: WebhookHeaders, secret: string, options?: VerifyWebhookOptions): WebhookEvent;
/** @deprecated Pass the request headers object instead: the body-only signature has no replay protection. */
export function parseWebhook(rawBody: Raw, signatureHeader: string | string[] | null | undefined, secret: string): WebhookEvent;
export function parseWebhook(rawBody: Raw, headersOrSignature: WebhookHeaders | HeaderValue, secret: string, options: VerifyWebhookOptions = {}): WebhookEvent {
  if (!secret) throw new TypeError('Callio: the webhook secret is required');
  const reason = isHeaders(headersOrSignature)
    ? check(rawBody, headersOrSignature, secret, options)
    : (checkLegacy(rawBody, headersOrSignature, secret) ? null : 'bad or missing X-NGX-Signature');
  if (reason) throw new WebhookVerificationError(`Callio webhook: ${reason}`, 401);
  let ev: unknown;
  try { ev = JSON.parse(bytes(rawBody).toString('utf8')); } catch { throw new WebhookVerificationError('Callio webhook: the body is not JSON', 400); }
  if (!ev || typeof ev !== 'object' || typeof (ev as { type?: unknown }).type !== 'string') throw new WebhookVerificationError('Callio webhook: no event type', 400);
  return ev as WebhookEvent;
}

/** Narrowing helpers. */
export const isOrderEvent = (e: WebhookEvent): e is OrderEvent => e.type.startsWith('order.');
export const isRecordingReady = (e: WebhookEvent): e is RecordingReadyEvent => e.type === 'recording.ready';
