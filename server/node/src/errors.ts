// Typed errors. Every failure from the API is a CallioError carrying the HTTP status and the server's
// `{ "error": "<reason>" }` message; the subclasses let callers branch with `instanceof`.

export class CallioError extends Error {
  /** HTTP status; 0 when no response arrived (network failure or timeout). */
  readonly status: number;
  /** The parsed response body, when there was one. */
  readonly body: unknown;
  /** The request's method and path (never the key), for logs. */
  readonly request: string | undefined;

  constructor(message: string, status = 0, body?: unknown, request?: string) {
    super(message);
    this.name = new.target.name;
    this.status = status;
    this.body = body;
    this.request = request;
  }
}

/** 400: invalid input (bad id or username, unknown user, wrong user type, missing reason…). */
export class ValidationError extends CallioError {}
/** 401: the API key is missing, wrong or revoked. */
export class AuthenticationError extends CallioError {}
/**
 * 403: the key is valid but the request is not allowed: the organisation is suspended, a seat quota is
 * reached, the user is disabled, or the call came from a network outside the organisation's API allow-list.
 */
export class PermissionDeniedError extends CallioError {}
/** 404: no such user, order, group or recording (or no transcript yet). */
export class NotFoundError extends CallioError {}
/** 409: it already exists (user, order). */
export class ConflictError extends CallioError {}
/** 410: the recording was deleted. */
export class GoneError extends CallioError {}
/** 429: the organisation's request rate is exceeded. `retryAfter` is in seconds, from the Retry-After header. */
export class RateLimitError extends CallioError {
  readonly retryAfter: number | undefined;
  constructor(message: string, status: number, body: unknown, request: string | undefined, retryAfter: number | undefined) {
    super(message, status, body, request);
    this.retryAfter = retryAfter;
  }
}
/** 5xx from the platform. */
export class ServerError extends CallioError {}
/** No response: DNS, TLS, connection reset… */
export class ConnectionError extends CallioError {}
/** No response within the configured timeout. */
export class TimeoutError extends ConnectionError {}

export function errorFor(status: number, message: string, body: unknown, request: string, retryAfter?: number): CallioError {
  switch (status) {
    case 400: case 422: return new ValidationError(message, status, body, request);
    case 401: return new AuthenticationError(message, status, body, request);
    case 403: return new PermissionDeniedError(message, status, body, request);
    case 404: return new NotFoundError(message, status, body, request);
    case 409: return new ConflictError(message, status, body, request);
    case 410: return new GoneError(message, status, body, request);
    case 429: return new RateLimitError(message, status, body, request, retryAfter);
    default: return status >= 500 ? new ServerError(message, status, body, request) : new CallioError(message, status, body, request);
  }
}
