using System.Diagnostics;
using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Clarigoinfotech.Callio.Server;

/// <summary>
/// The HTTP layer: a timeout per attempt, and retries with exponential backoff for idempotent requests (GET,
/// HEAD, PUT, DELETE, OPTIONS) on 429, 5xx and network errors. Redirects are never followed. The API key only
/// ever goes into the Authorization header; it is never part of an exception, a URL or <see cref="ToString"/>.
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class CallioHttp : IDisposable
{
    private static readonly HashSet<string> Idempotent = new(StringComparer.Ordinal) { "GET", "HEAD", "PUT", "DELETE", "OPTIONS" };

    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
    };

    [DebuggerBrowsable(DebuggerBrowsableState.Never)]
    private readonly string _apiKey;
    private readonly HttpClient _client;
    private readonly bool _ownsClient;

    /// <summary>The base URL, without a trailing slash.</summary>
    public string BaseUrl { get; }
    /// <summary>Per-attempt timeout.</summary>
    public TimeSpan Timeout { get; }
    /// <summary>Retries for idempotent requests.</summary>
    public int MaxRetries { get; }
    /// <summary>The User-Agent sent.</summary>
    public string UserAgent { get; }

    /// <summary>The wait before retry <c>attempt + 1</c>; <c>retryAfter</c> is null when the server sent none. Replaceable.</summary>
    public Func<int, TimeSpan?, TimeSpan> Backoff { get; set; } = DefaultBackoff;

    /// <summary>The sleep between retries (replaceable in tests).</summary>
    public Func<TimeSpan, CancellationToken, Task> Delay { get; set; } = Task.Delay;

    internal CallioHttp(string apiKey, string baseUrl, TimeSpan timeout, int maxRetries, string userAgent, HttpMessageHandler? handler)
    {
        _apiKey = apiKey;
        BaseUrl = baseUrl;
        Timeout = timeout;
        MaxRetries = maxRetries;
        UserAgent = userAgent;
        if (handler is null)
        {
            handler = new SocketsHttpHandler { AllowAutoRedirect = false };
            _client = new HttpClient(handler, disposeHandler: true);
        }
        else
        {
            DisableRedirects(handler);
            _client = new HttpClient(handler, disposeHandler: false);
        }
        _client.Timeout = System.Threading.Timeout.InfiniteTimeSpan;
        _ownsClient = true;
    }

    /// <summary>Turns off automatic redirects on every handler in the chain the SDK can reach.</summary>
    private static void DisableRedirects(HttpMessageHandler? h)
    {
        while (h is not null)
        {
            switch (h)
            {
                case SocketsHttpHandler s: s.AllowAutoRedirect = false; return;
                case HttpClientHandler c: c.AllowAutoRedirect = false; return;
                case DelegatingHandler d: h = d.InnerHandler; break;
                default: return;
            }
        }
    }

    /// <summary>Never prints the key.</summary>
    public override string ToString() => $"CallioHttp {{ BaseUrl = {BaseUrl}, Timeout = {Timeout}, MaxRetries = {MaxRetries} }}";

    /// <inheritdoc />
    public void Dispose()
    {
        if (_ownsClient) _client.Dispose();
    }

    internal static TimeSpan DefaultBackoff(int attempt, TimeSpan? retryAfter)
    {
        if (retryAfter is { } ra) return ra > TimeSpan.FromSeconds(60) ? TimeSpan.FromSeconds(60) : ra;
        var baseMs = Math.Min(8000, 500 * Math.Pow(2, attempt));
        return TimeSpan.FromMilliseconds(baseMs * (0.5 + Random.Shared.NextDouble() / 2));
    }

    /// <summary>Seconds or an HTTP date; null when absent or unreadable.</summary>
    public static TimeSpan? ParseRetryAfter(string? h)
    {
        if (string.IsNullOrWhiteSpace(h)) return null;
        h = h.Trim();
        if (double.TryParse(h, NumberStyles.Float, CultureInfo.InvariantCulture, out var n))
            return n >= 0 && !double.IsInfinity(n) ? TimeSpan.FromSeconds(n) : null;
        if (DateTimeOffset.TryParseExact(h, "r", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at))
            return TimeSpan.FromSeconds(Math.Max(0, Math.Ceiling((at - DateTimeOffset.UtcNow).TotalSeconds)));
        return null;
    }

    /// <summary>Sends a request and deserialises the JSON response (default for an empty body).</summary>
    public async Task<T?> RequestAsync<T>(HttpMethod method, string path, IEnumerable<KeyValuePair<string, object?>>? query = null, object? body = null, CancellationToken cancellationToken = default)
    {
        var (status, bytes) = await SendBufferedAsync(method, path, query, body, cancellationToken).ConfigureAwait(false);
        if (bytes.Length == 0) return default;
        try
        {
            return JsonSerializer.Deserialize<T>(bytes, Json);
        }
        catch (JsonException e)
        {
            throw new CallioException("Callio: could not decode the response: " + e.Message, status, Encoding.UTF8.GetString(bytes), $"{method.Method} {path}");
        }
    }

    /// <summary>Sends a request and returns the raw JSON (for endpoints the SDK doesn't wrap yet).</summary>
    public async Task<JsonElement?> RequestJsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, object?>>? query = null, object? body = null, CancellationToken cancellationToken = default)
    {
        var (_, bytes) = await SendBufferedAsync(method, path, query, body, cancellationToken).ConfigureAwait(false);
        if (bytes.Length == 0) return null;
        using var doc = JsonDocument.Parse(bytes);
        return doc.RootElement.Clone();
    }

    private async Task<(int, byte[])> SendBufferedAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, object?>>? query, object? body, CancellationToken ct)
    {
        var (res, cts, buffered) = await SendAsync(method, path, query, body, stream: false, ct).ConfigureAwait(false);
        using (cts)
        using (res)
        {
            return ((int)res.StatusCode, buffered ?? Array.Empty<byte>());
        }
    }

    /// <summary>
    /// Sends a request and returns the open response on a 2xx (for streaming). Dispose the result. The timeout
    /// covers getting the response headers.
    /// </summary>
    public async Task<StreamedResponse> RequestRawAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, object?>>? query = null, CancellationToken cancellationToken = default)
    {
        var (res, cts, _) = await SendAsync(method, path, query, null, stream: true, cancellationToken).ConfigureAwait(false);
        return new StreamedResponse(res, cts);
    }

    private async Task<(HttpResponseMessage, CancellationTokenSource, byte[]?)> SendAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, object?>>? query, object? body, bool stream, CancellationToken ct)
    {
        var label = $"{method.Method} {path}";
        var url = BaseUrl + path + Query.Encode(query);
        byte[]? payload = body is null ? null : JsonSerializer.SerializeToUtf8Bytes(body is PatchParams p ? p.Fields : body, body is PatchParams ? typeof(Dictionary<string, object?>) : body.GetType(), Json);
        var retryable = Idempotent.Contains(method.Method);

        for (var attempt = 0; ; attempt++)
        {
            using var req = new HttpRequestMessage(method, url);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);
            req.Headers.Accept.ParseAdd(stream ? "*/*" : "application/json");
            req.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
            if (payload is not null)
            {
                req.Content = new ByteArrayContent(payload);
                req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            }

            var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(Timeout);
            HttpResponseMessage res;
            byte[]? buffered = null;
            try
            {
                res = await _client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token).ConfigureAwait(false);
                var st = (int)res.StatusCode;
                if (!(st >= 200 && st < 300 && stream))
                {
                    buffered = await res.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false);
                }
            }
            catch (Exception e) when (e is HttpRequestException or OperationCanceledException or IOException)
            {
                var timedOut = cts.IsCancellationRequested && !ct.IsCancellationRequested;
                cts.Dispose();
                if (ct.IsCancellationRequested) throw;
                CallioException err = timedOut
                    ? new CallioTimeoutException($"Callio: no response within {Timeout.TotalMilliseconds} ms ({label})", 0, null, label)
                    : new ConnectionException($"Callio: could not reach {BaseUrl} ({label}): {e.Message}", 0, null, label);
                if (retryable && attempt < MaxRetries)
                {
                    await Delay(Backoff(attempt, null), ct).ConfigureAwait(false);
                    continue;
                }
                throw err;
            }

            var status = (int)res.StatusCode;
            if (status >= 200 && status < 300)
            {
                if (stream)
                {
                    // A streamed body is handed over once its headers arrive; the timeout covers getting that far.
                    cts.CancelAfter(System.Threading.Timeout.InfiniteTimeSpan);
                    return (res, cts, null);
                }
                return (res, cts, buffered);
            }
            var location = res.Headers.Location;
            var retryAfterHeader = res.Headers.RetryAfter;
            res.Dispose();
            cts.Dispose();

            if (status >= 300 && status < 400)
            {
                var where = location is { IsAbsoluteUri: true } l ? $"{l.Scheme}://{l.Authority}" : "another location";
                throw new RedirectException($"Callio: refusing to follow a redirect to {where} (the API key is never sent on a redirect); check the base URL", status, null, label);
            }
            TimeSpan? retryAfter = retryAfterHeader switch
            {
                { Delta: { } d } => d,
                { Date: { } dt } => TimeSpan.FromSeconds(Math.Max(0, Math.Ceiling((dt - DateTimeOffset.UtcNow).TotalSeconds))),
                _ => null,
            };
            if (retryable && (status == 429 || status >= 500) && attempt < MaxRetries)
            {
                await Delay(Backoff(attempt, retryAfter), ct).ConfigureAwait(false);
                continue;
            }
            var parsed = ParseBody(buffered);
            var msg = $"HTTP {status}";
            if (parsed is JsonElement { ValueKind: JsonValueKind.Object } o && o.TryGetProperty("error", out var er) && er.ValueKind == JsonValueKind.String) msg = er.GetString()!;
            else if (parsed is string s && s.Length > 0) msg = s.Length > 200 ? s[..200] : s;
            throw CallioException.ForStatus(status, msg, parsed, label, retryAfter);
        }
    }

    private static object? ParseBody(byte[]? raw)
    {
        if (raw is null || raw.Length == 0) return null;
        try
        {
            using var doc = JsonDocument.Parse(raw);
            return doc.RootElement.Clone();
        }
        catch (JsonException)
        {
            return Encoding.UTF8.GetString(raw);
        }
    }
}

/// <summary>An open streamed response. Dispose it to release the connection.</summary>
public sealed class StreamedResponse : IDisposable, IAsyncDisposable
{
    private readonly CancellationTokenSource _cts;

    internal StreamedResponse(HttpResponseMessage response, CancellationTokenSource cts)
    {
        Response = response;
        _cts = cts;
    }

    /// <summary>The response (2xx).</summary>
    public HttpResponseMessage Response { get; }

    /// <inheritdoc />
    public void Dispose()
    {
        Response.Dispose();
        _cts.Dispose();
    }

    /// <inheritdoc />
    public ValueTask DisposeAsync()
    {
        Dispose();
        return ValueTask.CompletedTask;
    }
}
