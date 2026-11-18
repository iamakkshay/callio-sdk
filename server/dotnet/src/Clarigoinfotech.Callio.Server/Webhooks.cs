using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Clarigoinfotech.Callio.Server;

/// <summary>Options for <see cref="Webhooks.VerifyRequest(ReadOnlySpan{byte}, Func{string, string?}, string, WebhookOptions?)"/>.</summary>
public sealed class WebhookOptions
{
    /// <summary>How far X-Callio-Timestamp may be from now (default 300 s).</summary>
    public TimeSpan Tolerance { get; init; } = Webhooks.DefaultTolerance;

    /// <summary>
    /// Accept a request without X-Callio-Timestamp by checking the legacy X-NGX-Signature (body only, so such a
    /// request could be a replay). Off by default.
    /// </summary>
    public bool AllowLegacy { get; init; }

    /// <summary>Replace the clock (tests).</summary>
    public TimeProvider Clock { get; init; } = TimeProvider.System;
}

/// <summary>
/// A verified webhook event. <see cref="Type"/> is always set; read other fields with <see cref="Raw"/>:
/// order.* (order, by), call.* / chat.* / location.* (callId, from, to, payload), recording.ready
/// (recordingId, durationSec, retainUntil; never audio), cc.chat-escalated (interaction, transcriptUrl),
/// report.snapshot (kpis, series). New types may be added; ignore ones you don't handle.
/// </summary>
public sealed class WebhookEvent
{
    internal WebhookEvent(JsonElement root)
    {
        Raw = root;
        Type = root.GetProperty("type").GetString()!;
        Id = root.TryGetProperty("id", out var id) ? id.ValueKind switch
        {
            JsonValueKind.String => id.GetString(),
            JsonValueKind.Number => id.GetRawText(),
            _ => null,
        } : null;
        TenantId = Str(root, "tenantId");
        At = Str(root, "at");
        By = Str(root, "by");
        CallId = Str(root, "callId");
        RecordingId = Str(root, "recordingId");
        if (root.TryGetProperty("order", out var o) && o.ValueKind == JsonValueKind.Object)
            Order = o.Deserialize<Order>(CallioHttp.Json);
    }

    private static string? Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    /// <summary>Unique per event: use it to drop duplicates (store the ids you have handled).</summary>
    public string? Id { get; }
    /// <summary>The event type, e.g. order.assigned.</summary>
    public string Type { get; }
    /// <summary>The organisation.</summary>
    public string? TenantId { get; }
    /// <summary>ISO 8601.</summary>
    public string? At { get; }
    /// <summary>The order, for order.* events.</summary>
    public Order? Order { get; }
    /// <summary><c>apikey:&lt;id&gt;</c> or <c>admin:&lt;username&gt;</c>, for order.* events.</summary>
    public string? By { get; }
    /// <summary>The call, for call.* / chat.* / recording.ready.</summary>
    public string? CallId { get; }
    /// <summary>The recording, for recording.ready.</summary>
    public string? RecordingId { get; }
    /// <summary>The whole event.</summary>
    public JsonElement Raw { get; }

    /// <summary>True for order.* events.</summary>
    public bool IsOrderEvent => Type.StartsWith("order.", StringComparison.Ordinal);
    /// <summary>True for recording.ready.</summary>
    public bool IsRecordingReady => Type == "recording.ready";
}

/// <summary>
/// Webhook verification. Callio POSTs JSON events to the organisation's webhook URL and signs them with the
/// webhook secret:
/// <code>
/// X-Callio-Timestamp: &lt;unix seconds&gt;
/// X-Callio-Signature: v1=&lt;hex HMAC-SHA256(secret, timestamp + "." + rawBody)&gt;
/// X-NGX-Signature:    sha256=&lt;hex HMAC-SHA256(secret, rawBody)&gt;   (legacy, no replay protection)
/// </code>
/// VerifyRequest / ParseRequest check the v1 signature and that the timestamp is within a tolerance (default 5
/// minutes), so a captured request cannot be replayed later. Verify the exact bytes received: re-serialising
/// parsed JSON changes them. Each event carries a unique Id.
/// </summary>
public static partial class Webhooks
{
    /// <summary>The legacy body-only signature header.</summary>
    public const string SignatureHeader = "X-NGX-Signature";
    /// <summary>The signing time, unix seconds.</summary>
    public const string TimestampHeader = "X-Callio-Timestamp";
    /// <summary>The timestamped signature, <c>v1=&lt;hex&gt;</c>.</summary>
    public const string SignatureV1Header = "X-Callio-Signature";
    /// <summary>The default timestamp tolerance.</summary>
    public static readonly TimeSpan DefaultTolerance = TimeSpan.FromSeconds(300);

    [GeneratedRegex("^sha256=([0-9a-fA-F]{64})$")] private static partial Regex LegacyRe();
    [GeneratedRegex("^v1=([0-9a-fA-F]{64})$")] private static partial Regex V1Re();

    private static void RequireSecret(string secret)
    {
        if (string.IsNullOrEmpty(secret)) throw new ArgumentException("Callio: the webhook secret is required", nameof(secret));
    }

    private static byte[] Mac(string secret, ReadOnlySpan<byte> prefix, ReadOnlySpan<byte> body)
    {
        using var h = IncrementalHash.CreateHMAC(HashAlgorithmName.SHA256, Encoding.UTF8.GetBytes(secret));
        h.AppendData(prefix);
        h.AppendData(body);
        return h.GetHashAndReset();
    }

    /// <summary>Any comma-separated signature in <paramref name="header"/> (rotation) equal to <paramref name="want"/>, in constant time.</summary>
    private static bool Matches(Regex re, string? header, byte[] want)
    {
        if (header is null) return false;
        var ok = false;
        foreach (var part in header.Split(','))
        {
            var m = re.Match(part.Trim());
            if (m.Success && CryptographicOperations.FixedTimeEquals(Convert.FromHexString(m.Groups[1].Value), want)) ok = true;
        }
        return ok;
    }

    /// <summary>The legacy <c>sha256=&lt;hex&gt;</c> value for this body.</summary>
    public static string Sign(ReadOnlySpan<byte> rawBody, string secret)
    {
        RequireSecret(secret);
        return "sha256=" + Convert.ToHexString(Mac(secret, default, rawBody)).ToLowerInvariant();
    }

    /// <summary>The <c>v1=&lt;hex&gt;</c> value Callio sends in X-Callio-Signature for this body and timestamp.</summary>
    public static string SignV1(ReadOnlySpan<byte> rawBody, long timestamp, string secret)
    {
        RequireSecret(secret);
        return "v1=" + Convert.ToHexString(Mac(secret, Encoding.UTF8.GetBytes(timestamp.ToString(CultureInfo.InvariantCulture) + "."), rawBody)).ToLowerInvariant();
    }

    /// <summary>
    /// The legacy check: <paramref name="signatureHeader"/> (X-NGX-Signature) is the HMAC-SHA256 of
    /// <paramref name="rawBody"/>. Constant-time; false for a missing or malformed header.
    /// </summary>
    [Obsolete("Cannot detect a replayed request; use VerifyRequest with the request headers.")]
    public static bool Verify(ReadOnlySpan<byte> rawBody, string? signatureHeader, string secret)
    {
        RequireSecret(secret);
        return Matches(LegacyRe(), signatureHeader, Mac(secret, default, rawBody));
    }

    /// <summary>See <see cref="Verify(ReadOnlySpan{byte}, string?, string)"/>.</summary>
    [Obsolete("Cannot detect a replayed request; use VerifyRequest with the request headers.")]
    public static bool Verify(string rawBody, string? signatureHeader, string secret) => Verify(Encoding.UTF8.GetBytes(rawBody), signatureHeader, secret);

    /// <summary>
    /// Checks a webhook request. Passes when X-Callio-Signature is valid for <c>X-Callio-Timestamp + "." + rawBody</c>
    /// and the timestamp is within the tolerance; otherwise throws <see cref="WebhookVerificationException"/>
    /// (status 401). A request without a timestamp is rejected unless AllowLegacy is set (then X-NGX-Signature is
    /// checked instead).
    /// </summary>
    /// <param name="rawBody">The exact bytes received.</param>
    /// <param name="header">Looks a header up by name, case-insensitively, e.g. <c>name =&gt; request.Headers[name]</c>.</param>
    /// <param name="secret">The webhook secret.</param>
    /// <param name="options">Tolerance, legacy fallback, clock.</param>
    public static void VerifyRequest(ReadOnlySpan<byte> rawBody, Func<string, string?> header, string secret, WebhookOptions? options = null)
    {
        RequireSecret(secret);
        ArgumentNullException.ThrowIfNull(header);
        var o = options ?? new WebhookOptions();
        if (o.Tolerance <= TimeSpan.Zero) throw new ArgumentException("Callio: the tolerance must be positive", nameof(options));
        var ts = header(TimestampHeader)?.Trim();
        if (string.IsNullOrEmpty(ts))
        {
            if (!o.AllowLegacy)
                throw new WebhookVerificationException($"Callio webhook: missing {TimestampHeader} (set AllowLegacy to accept body-only signatures)", 401);
            if (!Matches(LegacyRe(), header(SignatureHeader), Mac(secret, default, rawBody)))
                throw new WebhookVerificationException($"Callio webhook: bad or missing {SignatureHeader}", 401);
            return;
        }
        if (!long.TryParse(ts, NumberStyles.None, CultureInfo.InvariantCulture, out var t))
            throw new WebhookVerificationException($"Callio webhook: malformed {TimestampHeader}", 401);
        // The signature first, so a forged timestamp gets the same answer as a forged body.
        if (!Matches(V1Re(), header(SignatureV1Header), Mac(secret, Encoding.UTF8.GetBytes(ts + "."), rawBody)))
            throw new WebhookVerificationException($"Callio webhook: bad or missing {SignatureV1Header}", 401);
        var skew = Math.Abs(o.Clock.GetUtcNow().ToUnixTimeSeconds() - t);
        if (skew > o.Tolerance.TotalSeconds)
            throw new WebhookVerificationException($"Callio webhook: timestamp outside the {o.Tolerance.TotalSeconds} s tolerance (replayed or clock skew)", 401);
    }

    /// <summary>VerifyRequest with a header collection (any case; multi-valued entries use their first value).</summary>
    public static void VerifyRequest(ReadOnlySpan<byte> rawBody, IEnumerable<KeyValuePair<string, string>> headers, string secret, WebhookOptions? options = null) =>
        VerifyRequest(rawBody, Lookup(headers), secret, options);

    /// <summary>VerifyRequest with HttpHeaders-style values.</summary>
    public static void VerifyRequest(ReadOnlySpan<byte> rawBody, IEnumerable<KeyValuePair<string, IEnumerable<string>>> headers, string secret, WebhookOptions? options = null) =>
        VerifyRequest(rawBody, Lookup(headers), secret, options);

    /// <summary>Verifies the request (see VerifyRequest) and parses the event.</summary>
    public static WebhookEvent ParseRequest(ReadOnlySpan<byte> rawBody, Func<string, string?> header, string secret, WebhookOptions? options = null)
    {
        VerifyRequest(rawBody, header, secret, options);
        return Decode(rawBody);
    }

    /// <summary>ParseRequest with a header collection.</summary>
    public static WebhookEvent ParseRequest(ReadOnlySpan<byte> rawBody, IEnumerable<KeyValuePair<string, string>> headers, string secret, WebhookOptions? options = null) =>
        ParseRequest(rawBody, Lookup(headers), secret, options);

    /// <summary>Verifies the legacy X-NGX-Signature and parses the event.</summary>
    [Obsolete("Cannot detect a replayed request; use ParseRequest with the request headers.")]
    public static WebhookEvent Parse(ReadOnlySpan<byte> rawBody, string? signatureHeader, string secret)
    {
        if (!Verify(rawBody, signatureHeader, secret)) throw new WebhookVerificationException($"Callio webhook: bad or missing {SignatureHeader}", 401);
        return Decode(rawBody);
    }

    private static WebhookEvent Decode(ReadOnlySpan<byte> rawBody)
    {
        JsonElement root;
        try
        {
            var reader = new Utf8JsonReader(rawBody);
            using var doc = JsonDocument.ParseValue(ref reader);
            root = doc.RootElement.Clone();
        }
        catch (JsonException)
        {
            throw new WebhookVerificationException("Callio webhook: the body is not JSON", 400);
        }
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("type", out var t) || t.ValueKind != JsonValueKind.String)
            throw new WebhookVerificationException("Callio webhook: no event type", 400);
        return new WebhookEvent(root);
    }

    private static Func<string, string?> Lookup(IEnumerable<KeyValuePair<string, string>> headers)
    {
        ArgumentNullException.ThrowIfNull(headers);
        return name => headers.FirstOrDefault(h => string.Equals(h.Key, name, StringComparison.OrdinalIgnoreCase)).Value;
    }

    private static Func<string, string?> Lookup(IEnumerable<KeyValuePair<string, IEnumerable<string>>> headers)
    {
        ArgumentNullException.ThrowIfNull(headers);
        return name => headers.FirstOrDefault(h => string.Equals(h.Key, name, StringComparison.OrdinalIgnoreCase)).Value?.FirstOrDefault();
    }
}
