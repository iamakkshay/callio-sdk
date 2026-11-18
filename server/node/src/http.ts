// The HTTP layer: global fetch (Node >= 18), a timeout per attempt, and retries with exponential backoff
// for idempotent requests (GET, HEAD, PUT, DELETE) on 429, 5xx and network errors. The API key only ever
// goes into the Authorization header; it is never part of an error, a message or a URL.
import { CallioError, ConnectionError, TimeoutError, errorFor } from './errors.js';
import { VERSION } from './version.js';

export type FetchLike = (input: string, init: RequestInit) => Promise<Response>;

export interface CallioOptions {
  /** The tenant API key, `cio_<id>_<secret>`. Defaults to the CALLIO_API_KEY environment variable. */
  apiKey?: string;
  /** Your Callio host, e.g. `https://api.example.sa`. Defaults to CALLIO_BASE_URL. */
  baseUrl?: string;
  /** Per-attempt timeout in milliseconds (default 30000). */
  timeout?: number;
  /** Retries for idempotent requests on 429 / 5xx / network errors (default 2). */
  maxRetries?: number;
  /** Replace fetch (tests, proxies, instrumentation). */
  fetch?: FetchLike;
  /** Appended to the User-Agent, e.g. `my-backend/1.4`. */
  userAgent?: string;
  /**
   * Development only: allow an `http://` baseUrl (a local stack or a lab box). Without it the client
   * refuses anything but `https://`, so the API key never travels in clear text.
   */
  allowInsecure?: boolean;
}

export type Query = Record<string, string | number | boolean | Date | string[] | null | undefined>;

export interface RequestOptions {
  query?: Query;
  body?: unknown;
  /** Return the raw Response (for streaming) instead of parsed JSON. */
  raw?: boolean;
  signal?: AbortSignal;
}

const IDEMPOTENT = new Set(['GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS']);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export function encodeQuery(q: Query | undefined): string {
  if (!q) return '';
  const sp = new URLSearchParams();
  for (const [k, v] of Object.entries(q)) {
    if (v === undefined || v === null || v === '') continue;
    if (Array.isArray(v)) { if (v.length) sp.set(k, v.join(',')); continue; }
    sp.set(k, v instanceof Date ? v.toISOString() : String(v));
  }
  const s = sp.toString();
  return s ? `?${s}` : '';
}

export function parseRetryAfter(h: string | null): number | undefined {
  if (!h) return undefined;
  const n = Number(h);
  if (Number.isFinite(n) && n >= 0) return n;
  const t = Date.parse(h);
  return Number.isFinite(t) ? Math.max(0, Math.ceil((t - Date.now()) / 1000)) : undefined;
}

export class HttpClient {
  readonly baseUrl: string;
  readonly timeout: number;
  readonly maxRetries: number;
  readonly userAgent: string;
  readonly #apiKey: string;
  readonly #fetch: FetchLike;
  /** Overridable for tests. */
  backoff: (attempt: number, retryAfterSec: number | undefined) => number = (attempt, ra) =>
    ra !== undefined ? Math.min(ra, 60) * 1000 : Math.min(8000, 500 * 2 ** attempt) * (0.5 + Math.random() / 2);

  constructor(opts: CallioOptions = {}) {
    const env = typeof process !== 'undefined' ? process.env : {};
    const apiKey = opts.apiKey ?? env.CALLIO_API_KEY;
    const baseUrl = opts.baseUrl ?? env.CALLIO_BASE_URL;
    if (!apiKey) throw new CallioError('Callio: apiKey is required (or set CALLIO_API_KEY)');
    if (!baseUrl) throw new CallioError('Callio: baseUrl is required (or set CALLIO_BASE_URL), e.g. https://api.example.sa');
    let parsed: URL;
    try { parsed = new URL(baseUrl); } catch { throw new CallioError('Callio: baseUrl must be an https:// URL, e.g. https://api.example.sa'); }
    if (parsed.protocol === 'http:') {
      if (!opts.allowInsecure) throw new CallioError('Callio: baseUrl must use https://; http:// is allowed only for development with { allowInsecure: true }');
    } else if (parsed.protocol !== 'https:') {
      throw new CallioError('Callio: baseUrl must be an https:// URL, e.g. https://api.example.sa');
    }
    this.#apiKey = apiKey;
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.timeout = opts.timeout ?? 30_000;
    this.maxRetries = Math.max(0, opts.maxRetries ?? 2);
    const f = opts.fetch ?? (globalThis.fetch as FetchLike | undefined);
    if (!f) throw new CallioError('Callio: global fetch is not available; use Node.js 18+ or pass options.fetch');
    this.#fetch = f;
    const node = typeof process !== 'undefined' ? ` node/${process.versions?.node ?? '?'}` : '';
    this.userAgent = `callio-server-node/${VERSION}${node}${opts.userAgent ? ` ${opts.userAgent}` : ''}`;
  }

  /** Never print the key. */
  toJSON() { return { baseUrl: this.baseUrl, timeout: this.timeout, maxRetries: this.maxRetries }; }
  [Symbol.for('nodejs.util.inspect.custom')]() { return `HttpClient ${JSON.stringify(this.toJSON())}`; }

  async request<T>(method: string, path: string, opts: RequestOptions & { raw: true }): Promise<Response>;
  async request<T>(method: string, path: string, opts?: RequestOptions): Promise<T>;
  async request<T>(method: string, path: string, opts: RequestOptions = {}): Promise<T | Response> {
    const url = `${this.baseUrl}${path}${encodeQuery(opts.query)}`;
    const label = `${method} ${path}`;
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.#apiKey}`,
      Accept: opts.raw ? '*/*' : 'application/json',
      'User-Agent': this.userAgent,
    };
    let payload: string | undefined;
    if (opts.body !== undefined) { headers['Content-Type'] = 'application/json'; payload = JSON.stringify(opts.body); }
    const retryable = IDEMPOTENT.has(method);

    for (let attempt = 0; ; attempt++) {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), this.timeout);
      const onAbort = () => ctrl.abort();
      opts.signal?.addEventListener('abort', onAbort, { once: true });
      let res: Response;
      try {
        // Never follow a redirect: fetch would re-send the Authorization header to wherever it points
        // (whether it strips it on a host change depends on the runtime version).
        res = await this.#fetch(url, { method, headers, body: payload, signal: ctrl.signal, redirect: 'manual' });
      } catch (e) {
        clearTimeout(timer);
        opts.signal?.removeEventListener('abort', onAbort);
        if (opts.signal?.aborted) throw e;
        const timedOut = ctrl.signal.aborted;
        const err = timedOut
          ? new TimeoutError(`Callio: no response within ${this.timeout} ms (${label})`, 0, undefined, label)
          : new ConnectionError(`Callio: could not reach ${this.baseUrl} (${label}): ${(e as Error)?.message ?? e}`, 0, undefined, label);
        if (retryable && attempt < this.maxRetries) { await sleep(this.backoff(attempt, undefined)); continue; }
        throw err;
      }
      // A streamed (raw) body is handed over once its headers arrive; the timeout covers getting that far.
      opts.signal?.removeEventListener('abort', onAbort);

      if (res.type === 'opaqueredirect' || (res.status >= 300 && res.status < 400)) {
        clearTimeout(timer);
        try { await res.body?.cancel(); } catch { /* ignore */ }
        throw new CallioError(
          `Callio: the server answered with a redirect (HTTP ${res.status || '3xx'}) for ${label}; redirects are not followed so the API key is never sent elsewhere. Set baseUrl to the final https:// address.`,
          res.status, undefined, label);
      }

      if (res.ok && opts.raw) { clearTimeout(timer); return res; }
      let text = '';
      try { text = await res.text(); } catch (e) {
        clearTimeout(timer);
        const err = new ConnectionError(`Callio: the response was cut off (${label})`, res.status, undefined, label);
        if (retryable && attempt < this.maxRetries) { await sleep(this.backoff(attempt, undefined)); continue; }
        throw err;
      }
      clearTimeout(timer);
      let body: unknown = undefined;
      if (text) { try { body = JSON.parse(text); } catch { body = text; } }
      if (res.ok) return body as T;

      const retryAfter = parseRetryAfter(res.headers.get('retry-after'));
      if (retryable && (res.status === 429 || res.status >= 500) && attempt < this.maxRetries) {
        await sleep(this.backoff(attempt, retryAfter));
        continue;
      }
      const msg = (body && typeof body === 'object' && typeof (body as { error?: unknown }).error === 'string')
        ? (body as { error: string }).error
        : (typeof body === 'string' && body ? body.slice(0, 200) : `HTTP ${res.status}`);
      throw errorFor(res.status, msg, body, label, retryAfter);
    }
  }
}
