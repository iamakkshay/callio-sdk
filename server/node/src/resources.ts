// One class per API namespace, mirroring /api/v1.
import { createWriteStream } from 'node:fs';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import type { ReadableStream as NodeWebReadableStream } from 'node:stream/web';
import { ConflictError, ValidationError } from './errors.js';
import type { HttpClient } from './http.js';
import type * as T from './types.js';

const seg = (s: string) => {
  if (typeof s !== 'string' || !s) throw new TypeError('Callio: an id / username is required');
  // encodeURIComponent leaves '.' alone, and a '.' or '..' segment would be resolved as a relative path.
  if (s === '.' || s === '..') throw new ValidationError(`Callio: "${s}" is not a valid id / username`);
  return encodeURIComponent(s);
};

export class Users {
  constructor(private readonly http: HttpClient) {}
  /** Search users. */
  async list(params: T.ListUsersParams = {}): Promise<T.User[]> {
    return (await this.http.request<{ users: T.User[] }>('GET', '/api/v1/users', { query: { ...params } })).users;
  }
  /** Create a user. Throws ConflictError (409) if the username exists, PermissionDeniedError (403) if the seat quota is reached. */
  async create(params: T.CreateUserParams): Promise<T.CreatedUser> {
    return (await this.http.request<{ user: T.CreatedUser }>('POST', '/api/v1/users', { body: params })).user;
  }
  async get(username: string): Promise<T.User> {
    return (await this.http.request<{ user: T.User }>('GET', `/api/v1/users/${seg(username)}`)).user;
  }
  /** Changing the type or disabling ends the user's sessions. */
  async update(username: string, params: T.UpdateUserParams): Promise<T.User> {
    return (await this.http.request<{ user: T.User }>('PATCH', `/api/v1/users/${seg(username)}`, { body: params })).user;
  }
  async disable(username: string): Promise<T.User> { return this.update(username, { disabled: true }); }
  async enable(username: string): Promise<T.User> { return this.update(username, { disabled: false }); }
  /** End every session the user has open. */
  async signOut(username: string): Promise<T.Ok> {
    return this.http.request<T.Ok>('POST', `/api/v1/users/${seg(username)}/sign-out`);
  }
  /** PDPL access request: everything held about the user. */
  async export(username: string): Promise<T.UserExport> {
    return this.http.request<T.UserExport>('GET', `/api/v1/users/${seg(username)}/export`);
  }
  /** PDPL erasure: deletes the account and its data (recordings on legal hold are kept). Irreversible. */
  async delete(username: string, params: { reason: string }): Promise<T.ErasureResult> {
    return this.http.request<T.ErasureResult>('DELETE', `/api/v1/users/${seg(username)}`, { body: { reason: params.reason } });
  }
}

export class Tokens {
  constructor(private readonly http: HttpClient, private readonly users: Users) {}
  /** A short-lived app token for an existing user (60–3600 s, default 900). */
  async create(params: T.CreateTokenParams): Promise<T.Token> {
    return this.http.request<T.Token>('POST', '/api/v1/tokens', { body: params });
  }
  /**
   * The common job: make sure the app user exists, then issue their token. Creates the user if missing
   * (a 409 means they already exist, which is fine) and returns the token. An existing user's display
   * name and type are left as they are; check `userType` on the result if it matters.
   */
  async forUser(username: string, opts: T.ForUserOptions = {}): Promise<T.UserToken> {
    let created = false;
    try {
      await this.users.create({ username, displayName: opts.displayName, userType: opts.userType, phone: opts.phone });
      created = true;
    } catch (e) {
      if (!(e instanceof ConflictError)) throw e;
    }
    const t = await this.create({ username, ttlSec: opts.ttlSec, deviceId: opts.deviceId });
    return { ...t, created };
  }
}

export class Orders {
  constructor(private readonly http: HttpClient) {}
  /** Throws ConflictError if the id exists, ValidationError for an unknown customer/agent or a wrong user type. */
  async create(params: T.CreateOrderParams): Promise<T.Order> {
    return (await this.http.request<{ order: T.Order }>('POST', '/api/v1/orders', { body: params })).order;
  }
  async list(params: T.ListOrdersParams = {}): Promise<T.Order[]> {
    return (await this.http.request<{ orders: T.Order[] }>('GET', '/api/v1/orders', { query: { ...params } })).orders;
  }
  async get(id: string): Promise<T.Order> {
    return (await this.http.request<{ order: T.Order }>('GET', `/api/v1/orders/${seg(id)}`)).order;
  }
  /** Reassign (`agent`), unassign (`agent: null`), close or reopen (`status`), relabel. */
  async update(id: string, params: T.UpdateOrderParams): Promise<T.Order> {
    return (await this.http.request<{ order: T.Order }>('PATCH', `/api/v1/orders/${seg(id)}`, { body: params })).order;
  }
  assign(id: string, agent: string | null) { return this.update(id, { agent }); }
  close(id: string) { return this.update(id, { status: 'closed' }); }
  reopen(id: string) { return this.update(id, { status: 'active' }); }
}

export class Recordings {
  constructor(private readonly http: HttpClient) {}
  async list(params: T.ListRecordingsParams = {}): Promise<T.Recording[]> {
    return (await this.http.request<{ recordings: T.Recording[] }>('GET', '/api/v1/recordings', { query: { ...params } })).recordings;
  }
  async get(id: string): Promise<T.Recording> {
    return (await this.http.request<{ recording: T.Recording }>('GET', `/api/v1/recordings/${seg(id)}`)).recording;
  }
  /**
   * Stream the audio. The reason (at least 5 characters) is required and goes into the recording's access
   * trail. Consume `body` (or cancel it) promptly.
   */
  async audio(id: string, params: T.ReasonParams, opts: { signal?: AbortSignal } = {}): Promise<T.RecordingAudio> {
    const res = await this.http.request('GET', `/api/v1/recordings/${seg(id)}/audio`, { query: { reason: requireReason(params) }, raw: true, signal: opts.signal });
    if (!res.body) throw new TypeError('Callio: the audio response had no body');
    const len = res.headers.get('content-length');
    return { body: res.body, contentType: res.headers.get('content-type') || 'audio/ogg', contentLength: len ? Number(len) : null };
  }
  /** Stream the audio straight to a file; returns the number of bytes written. */
  async download(id: string, filePath: string, params: T.ReasonParams): Promise<number> {
    const a = await this.audio(id, params);
    const src = Readable.fromWeb(a.body as unknown as NodeWebReadableStream<Uint8Array>);
    let n = 0;
    src.on('data', (c: Buffer) => { n += c.length; });
    await pipeline(src, createWriteStream(filePath));
    return n;
  }
  /** The transcript; same rules as the audio (a reason, and the read is logged). NotFoundError while it is still being transcribed. */
  async transcript(id: string, params: T.ReasonParams): Promise<T.Transcript> {
    return (await this.http.request<{ transcript: T.Transcript }>('GET', `/api/v1/recordings/${seg(id)}/transcript`, { query: { reason: requireReason(params) } })).transcript;
  }
}

function requireReason(p: T.ReasonParams | undefined): string {
  const r = String(p?.reason ?? '').trim();
  if (r.length < 5) throw new TypeError('Callio: a reason of at least 5 characters is required to fetch a recording');
  return r;
}

export class Groups {
  constructor(private readonly http: HttpClient) {}
  async create(params: T.CreateGroupParams): Promise<T.Group> {
    return (await this.http.request<{ group: T.Group }>('POST', '/api/v1/groups', { body: params })).group;
  }
  async list(): Promise<T.Group[]> {
    return (await this.http.request<{ groups: T.Group[] }>('GET', '/api/v1/groups')).groups;
  }
  async get(id: string): Promise<T.Group> {
    return (await this.http.request<{ group: T.Group }>('GET', `/api/v1/groups/${seg(id)}`)).group;
  }
  /** Rename, add or remove members. Members added later see messages from when they joined. */
  async update(id: string, params: T.UpdateGroupParams): Promise<T.Group> {
    return (await this.http.request<{ group: T.Group }>('PATCH', `/api/v1/groups/${seg(id)}`, { body: params })).group;
  }
  /** Deletes the group and its messages. */
  async delete(id: string): Promise<T.Ok> {
    return this.http.request<T.Ok>('DELETE', `/api/v1/groups/${seg(id)}`);
  }
}

export class Events {
  constructor(private readonly http: HttpClient) {}
  /** One page of the event feed, in order. Pass the returned `next` as `after` for the following page. */
  async list(params: T.ListEventsParams = {}): Promise<T.EventPage> {
    return this.http.request<T.EventPage>('GET', '/api/v1/events', { query: { after: params.after, limit: params.limit, types: params.types } });
  }
  /** Every event after `after`, page by page, until the feed is caught up. Remember the last `id` to resume. */
  async *iterate(params: T.ListEventsParams = {}): AsyncGenerator<T.CallioEvent, void, undefined> {
    let after = params.after ?? 0;
    for (;;) {
      const page = await this.list({ ...params, after });
      for (const e of page.events) yield e;
      if (!page.events.length || page.next <= after) return;
      after = page.next;
    }
  }
}

export class Cdr {
  constructor(private readonly http: HttpClient) {}
  /** Call records for the last `days` (1–90, default 7): one row per call. */
  async list(params: T.ListCdrParams = {}): Promise<T.CdrPage> {
    return this.http.request<T.CdrPage>('GET', '/api/v1/cdr', { query: { ...params } });
  }
}
