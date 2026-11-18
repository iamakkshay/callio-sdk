package com.clarigoinfotech.callio;

/**
 * Every failure from the API: the HTTP status and the server's {@code {"error": "<reason>"}} message.
 * Subclasses let callers branch with {@code catch}. Unchecked. Never contains the API key.
 */
public class CallioException extends RuntimeException {
  private static final long serialVersionUID = 1L;

  private final int status;
  private final transient Object body;
  private final String request;

  public CallioException(String message) { this(message, 0, null, null); }

  public CallioException(String message, int status, Object body, String request) {
    super(message);
    this.status = status;
    this.body = body;
    this.request = request;
  }

  /** HTTP status; 0 when no response arrived (network failure or timeout). */
  public int status() { return status; }

  /** The parsed response body (a Map, a String or null). */
  public Object body() { return body; }

  /** The request's method and path, e.g. {@code GET /api/v1/orders/X} (never the key), for logs. */
  public String request() { return request; }

  static CallioException forStatus(int status, String message, Object body, String request, java.time.Duration retryAfter) {
    switch (status) {
      case 400: case 422: return new ValidationException(message, status, body, request);
      case 401: return new AuthenticationException(message, status, body, request);
      case 403: return new PermissionDeniedException(message, status, body, request);
      case 404: return new NotFoundException(message, status, body, request);
      case 409: return new ConflictException(message, status, body, request);
      case 410: return new GoneException(message, status, body, request);
      case 429: return new RateLimitException(message, status, body, request, retryAfter);
      default:
        if (status >= 300 && status < 400) return new RedirectException(message, status, body, request);
        return status >= 500 ? new ServerException(message, status, body, request) : new CallioException(message, status, body, request);
    }
  }
}
