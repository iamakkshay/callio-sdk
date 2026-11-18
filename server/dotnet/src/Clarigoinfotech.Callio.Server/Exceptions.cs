namespace Clarigoinfotech.Callio.Server;

/// <summary>
/// Every failure from the API: the HTTP status and the server's <c>{"error": "&lt;reason&gt;"}</c> message.
/// Subclasses let callers branch with <c>catch</c>. Never contains the API key.
/// </summary>
public class CallioException : Exception
{
    /// <summary>HTTP status; 0 when no response arrived (network failure or timeout).</summary>
    public int Status { get; }

    /// <summary>The parsed response body (a <see cref="System.Text.Json.JsonElement"/> or a string), when there was one.</summary>
    public object? Body { get; }

    /// <summary>The method and path, e.g. <c>GET /api/v1/orders/X</c> (never the key), for logs.</summary>
    public string? Request { get; }

    /// <summary>Creates the exception.</summary>
    public CallioException(string message, int status = 0, object? body = null, string? request = null) : base(message)
    {
        Status = status;
        Body = body;
        Request = request;
    }

    internal static CallioException ForStatus(int status, string message, object? body, string request, TimeSpan? retryAfter) => status switch
    {
        400 or 422 => new ValidationException(message, status, body, request),
        401 => new AuthenticationException(message, status, body, request),
        403 => new PermissionDeniedException(message, status, body, request),
        404 => new NotFoundException(message, status, body, request),
        409 => new ConflictException(message, status, body, request),
        410 => new GoneException(message, status, body, request),
        429 => new RateLimitException(message, status, body, request, retryAfter),
        >= 300 and < 400 => new RedirectException(message, status, body, request),
        >= 500 => new ServerException(message, status, body, request),
        _ => new CallioException(message, status, body, request),
    };
}

/// <summary>400: invalid input (bad id or username, unknown user, wrong user type, missing reason…).</summary>
public class ValidationException(string message, int status = 400, object? body = null, string? request = null) : CallioException(message, status, body, request);

/// <summary>401: the API key is missing, wrong or revoked.</summary>
public class AuthenticationException(string message, int status = 401, object? body = null, string? request = null) : CallioException(message, status, body, request);

/// <summary>
/// 403: the organisation is suspended, a seat quota is reached, the user is disabled, or the call came from a
/// network outside the organisation's API allow-list.
/// </summary>
public class PermissionDeniedException(string message, int status = 403, object? body = null, string? request = null) : CallioException(message, status, body, request);

/// <summary>404: no such user, order, group or recording (or no transcript yet).</summary>
public class NotFoundException(string message, int status = 404, object? body = null, string? request = null) : CallioException(message, status, body, request);

/// <summary>409: it already exists (user, order).</summary>
public class ConflictException(string message, int status = 409, object? body = null, string? request = null) : CallioException(message, status, body, request);

/// <summary>410: the recording was deleted.</summary>
public class GoneException(string message, int status = 410, object? body = null, string? request = null) : CallioException(message, status, body, request);

/// <summary>429: the organisation's request rate is exceeded. <see cref="RetryAfter"/> is from the Retry-After header.</summary>
public class RateLimitException(string message, int status = 429, object? body = null, string? request = null, TimeSpan? retryAfter = null) : CallioException(message, status, body, request)
{
    /// <summary>How long the server asked to wait, when it said.</summary>
    public TimeSpan? RetryAfter { get; } = retryAfter;
}

/// <summary>5xx from the platform.</summary>
public class ServerException(string message, int status = 500, object? body = null, string? request = null) : CallioException(message, status, body, request);

/// <summary>No response: DNS, TLS, connection reset…</summary>
public class ConnectionException(string message, int status = 0, object? body = null, string? request = null) : CallioException(message, status, body, request);

/// <summary>No response within the configured timeout.</summary>
public class CallioTimeoutException(string message, int status = 0, object? body = null, string? request = null) : ConnectionException(message, status, body, request);

/// <summary>
/// 3xx: the server answered with a redirect. The SDK never follows one (it would carry the API key to another
/// host); usually the base URL is wrong (http:// instead of https://, or a moved host).
/// </summary>
public class RedirectException(string message, int status, object? body = null, string? request = null) : CallioException(message, status, body, request);

/// <summary>A bad or missing webhook signature or timestamp (status 401), or a body that is not a Callio event (400).</summary>
public class WebhookVerificationException(string message, int status) : CallioException(message, status);
