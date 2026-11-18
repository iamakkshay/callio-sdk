// Models returned by the Callio tenant API (/api/v1). Field names match the JSON on the wire.

export type UserType = 'customer' | 'agent';
export type OrderStatus = 'active' | 'closed';

export interface User {
  username: string;
  displayName: string | null;
  userType: UserType | 'guest';
  /** The user's SIP extension. */
  extension: string;
  segment: string | null;
  disabled: boolean;
  /** Masked phone fallback number (only on get/create/update, not in list results). */
  phone?: string | null;
}

export interface CreatedUser extends User {
  /** Returned once, when the user was created without a loginPassword. */
  initialPassword?: string;
}

export interface ListUsersParams { q?: string; type?: UserType; status?: 'active' | 'disabled'; segment?: string; limit?: number }
export interface CreateUserParams { username: string; displayName?: string; userType?: UserType; loginPassword?: string; phone?: string }
export interface UpdateUserParams { displayName?: string; userType?: UserType; disabled?: boolean; segment?: string | null; phone?: string | null }

export interface ErasureResult {
  ok: true;
  /** The pseudonym that replaced the user in records that are kept (events, orders, others' messages). */
  alias: string;
  removed: Record<string, number>;
  recordingsKeptOnLegalHold: string[];
}

/** PDPL access-request export: everything held about a user. The shape is the platform's and may grow. */
export type UserExport = Record<string, unknown> & { exportedAt: string; tenant: string };

export interface Token {
  /** A short-lived JWT for the app SDKs. */
  token: string;
  userType: UserType;
  expiresAt: string;
}
export interface CreateTokenParams {
  username: string;
  /** 60–3600, default 900. */ ttlSec?: number;
  /** The app's device id (its X-Device-Id): the token works on that device only. Without it, on the first device that uses it. */
  deviceId?: string;
}
export interface ForUserOptions { displayName?: string; userType?: UserType; ttlSec?: number; phone?: string; /** See CreateTokenParams.deviceId. */ deviceId?: string }
export interface UserToken extends Token {
  /** True when forUser() created the user on this call. */
  created: boolean;
}

export interface Order {
  id: string;
  customer: string;
  agent: string | null;
  status: OrderStatus;
  label: string | null;
  createdAt: string;
  updatedAt: string;
  closedAt: string | null;
}
export interface CreateOrderParams { id: string; customer: string; agent?: string; label?: string }
export interface UpdateOrderParams { agent?: string | null; status?: OrderStatus; label?: string | null }
export interface ListOrdersParams { status?: OrderStatus; user?: string; limit?: number }

export interface Recording {
  id: string;
  tenant: string;
  callRef: string | null;
  caller: string | null;
  callee: string | null;
  callType: string | null;
  orderId: string | null;
  startedAt: string | null;
  durationSec: number;
  bytes: number;
  format: string | null;
  status: 'stored' | 'deleted';
  legalHold: boolean;
  holdReason: string | null;
  retainUntil: string | null;
  deletedAt: string | null;
  deleteReason: string | null;
  createdAt: string;
  transcript: { status: string; language: string | null; error: string | null } | null;
}
export interface ListRecordingsParams {
  /** ISO date (or Date). */ from?: string | Date;
  /** ISO date (or Date). */ to?: string | Date;
  /** Extension of either party. */ user?: string;
  callId?: string;
  orderId?: string;
  minDuration?: number;
  maxDuration?: number;
  status?: 'stored' | 'deleted' | 'all';
  limit?: number;
}
export interface ReasonParams { /** Why it is being fetched (at least 5 characters); kept in the recording's access trail. */ reason: string }
export interface Transcript {
  text: string;
  language?: string | null;
  segments?: Array<{ start: number; end: number; text: string; [k: string]: unknown }>;
  [k: string]: unknown;
}
export interface RecordingAudio {
  /** The audio bytes as a web ReadableStream (stereo Ogg/Opus, caller left). Consume or cancel it. */
  body: ReadableStream<Uint8Array>;
  contentType: string;
  contentLength: number | null;
}

export interface GroupMember { username: string; displayName: string | null; userType: string; sipUser: string }
export interface Group { id: string; name: string; createdAt: string; members: GroupMember[] }
export interface CreateGroupParams { id: string; name: string; /** 2–50 usernames. */ members: string[] }
export interface UpdateGroupParams { name?: string; add?: string[]; remove?: string[] }

export interface CallioEvent {
  id: number;
  type: string;
  callId: string | null;
  from: string | null;
  to: string | null;
  fromType: string | null;
  toType: string | null;
  orderId: string | null;
  at: string;
  payload: Record<string, unknown>;
}
export interface ListEventsParams { after?: number; limit?: number; /** Type prefixes, e.g. ['call.', 'chat.']. */ types?: string[] | string }
export interface EventPage { events: CallioEvent[]; next: number }

export interface CallRecord {
  callId: string;
  tenant: string;
  from: string | null;
  to: string | null;
  fromType: string | null;
  toType: string | null;
  direction: string;
  support: boolean;
  orderId: string | null;
  entryPoint: string | null;
  outcome: string;
  endReason: string;
  durationSec: number;
  answerSec: number | null;
  startedAt: string | null;
  answeredAt: string | null;
  endedAt: string | null;
  quality: unknown;
  client: unknown;
}
export interface ListCdrParams { /** 1–90, default 7. */ days?: number; type?: UserType | 'guest' }
export interface CdrPage { days: number; calls: CallRecord[] }

export interface Ok { ok: true }
