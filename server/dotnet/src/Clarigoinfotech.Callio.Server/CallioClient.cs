using System.Diagnostics;
using System.Text.RegularExpressions;

namespace Clarigoinfotech.Callio.Server;

/// <summary>Options for <see cref="CallioClient"/>.</summary>
public sealed class CallioOptions
{
    /// <summary>The tenant API key, <c>cio_&lt;id&gt;_&lt;secret&gt;</c>. Defaults to the CALLIO_API_KEY environment variable.</summary>
    [DebuggerBrowsable(DebuggerBrowsableState.Never)]
    public string? ApiKey { get; set; }
    /// <summary>Your Callio host, e.g. <c>https://api.example.sa</c>. Defaults to CALLIO_BASE_URL.</summary>
    public string? BaseUrl { get; set; }
    /// <summary>Per-attempt timeout (default 30 s).</summary>
    public TimeSpan Timeout { get; set; } = TimeSpan.FromSeconds(30);
    /// <summary>Retries for idempotent requests on 429 / 5xx / network errors (default 2).</summary>
    public int MaxRetries { get; set; } = 2;
    /// <summary>Appended to the User-Agent, e.g. <c>my-backend/1.4</c>.</summary>
    public string? UserAgent { get; set; }
    /// <summary>Permit an http:// base URL. Only for a local development stack: the key travels in clear text.</summary>
    public bool AllowInsecure { get; set; }
    /// <summary>
    /// Replace the HTTP handler (proxies, tests, instrumentation). The SDK turns off its automatic redirects and
    /// does not dispose it.
    /// </summary>
    public HttpMessageHandler? HttpMessageHandler { get; set; }

    /// <summary>Never prints the key.</summary>
    public override string ToString() => $"CallioOptions {{ BaseUrl = {BaseUrl}, Timeout = {Timeout}, MaxRetries = {MaxRetries} }}";
}

/// <summary>
/// The Callio tenant API client. Keep it on your server: the API key gives full access to your organisation's
/// users, orders and recordings. Thread-safe; create one (e.g. a singleton) and share it.
/// <code>
/// var callio = new CallioClient(new CallioOptions { ApiKey = Environment.GetEnvironmentVariable("CALLIO_API_KEY"), BaseUrl = "https://api.example.sa" });
/// var t = await callio.Tokens.ForUserAsync("cust-42", new ForUserOptions { DisplayName = "Sara", UserType = UserType.Customer });
/// </code>
/// </summary>
[DebuggerDisplay("{ToString(),nq}")]
public sealed class CallioClient : IDisposable
{
    /// <summary>App users.</summary>
    public Users Users { get; }
    /// <summary>App tokens.</summary>
    public Tokens Tokens { get; }
    /// <summary>Orders.</summary>
    public Orders Orders { get; }
    /// <summary>Recordings.</summary>
    public Recordings Recordings { get; }
    /// <summary>Group chats.</summary>
    public Groups Groups { get; }
    /// <summary>The event feed.</summary>
    public Events Events { get; }
    /// <summary>Call records.</summary>
    public Cdr Cdr { get; }
    /// <summary>The underlying HTTP client (RequestAsync for endpoints the SDK doesn't wrap yet).</summary>
    public CallioHttp Http { get; }

    /// <summary>The SDK version.</summary>
    public const string Version = "0.1.0";

    /// <summary>Creates a client; with no options, from CALLIO_API_KEY and CALLIO_BASE_URL.</summary>
    public CallioClient(CallioOptions? options = null)
    {
        var o = options ?? new CallioOptions();
        var key = string.IsNullOrEmpty(o.ApiKey) ? Environment.GetEnvironmentVariable("CALLIO_API_KEY") : o.ApiKey;
        var url = string.IsNullOrEmpty(o.BaseUrl) ? Environment.GetEnvironmentVariable("CALLIO_BASE_URL") : o.BaseUrl;
        if (string.IsNullOrEmpty(key)) throw new CallioException("Callio: ApiKey is required (or set CALLIO_API_KEY)");
        if (string.IsNullOrEmpty(url)) throw new CallioException("Callio: BaseUrl is required (or set CALLIO_BASE_URL), e.g. https://api.example.sa");
        var https = Regex.IsMatch(url, "^https://[^/]", RegexOptions.IgnoreCase);
        var http = Regex.IsMatch(url, "^http://[^/]", RegexOptions.IgnoreCase);
        if (!https && !(o.AllowInsecure && http))
            throw new CallioException("Callio: BaseUrl must start with https:// (http:// only with AllowInsecure = true, for a local stack)");
        if (o.Timeout <= TimeSpan.Zero) throw new CallioException("Callio: Timeout must be positive");
        var ua = $"callio-server-dotnet/{Version} dotnet/{Environment.Version}" + (string.IsNullOrEmpty(o.UserAgent) ? "" : " " + o.UserAgent);
        Http = new CallioHttp(key, url.TrimEnd('/'), o.Timeout, Math.Max(0, o.MaxRetries), ua, o.HttpMessageHandler);
        Users = new Users(Http);
        Tokens = new Tokens(Http, Users);
        Orders = new Orders(Http);
        Recordings = new Recordings(Http);
        Groups = new Groups(Http);
        Events = new Events(Http);
        Cdr = new Cdr(Http);
    }

    /// <summary>Never prints the key.</summary>
    public override string ToString() => $"CallioClient {{ BaseUrl = {Http.BaseUrl} }}";

    /// <inheritdoc />
    public void Dispose() => Http.Dispose();
}
