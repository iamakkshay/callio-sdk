package com.clarigoinfotech.callio;

import java.nio.charset.StandardCharsets;
import java.security.InvalidKeyException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Duration;
import java.util.Collection;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.function.Function;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Webhook verification. Callio POSTs JSON events to the organisation's webhook URL and signs them with the
 * webhook secret:
 * <pre>
 * X-Callio-Timestamp: &lt;unix seconds&gt;
 * X-Callio-Signature: v1=&lt;hex HMAC-SHA256(secret, timestamp + "." + rawBody)&gt;
 * X-NGX-Signature:    sha256=&lt;hex HMAC-SHA256(secret, rawBody)&gt;   (legacy, no replay protection)
 * </pre>
 * {@link #verifyRequest} / {@link #parseRequest} check the v1 signature and that the timestamp is within a
 * tolerance (default 5 minutes), so a captured request cannot be replayed later. Verify the exact bytes
 * received: re-serialising parsed JSON changes them. Each event carries a unique {@code id}.
 */
public final class Webhooks {
  private Webhooks() {}

  /** The legacy body-only signature header. */
  public static final String SIGNATURE_HEADER = "X-NGX-Signature";
  /** The signing time, unix seconds. */
  public static final String TIMESTAMP_HEADER = "X-Callio-Timestamp";
  /** The timestamped signature, {@code v1=<hex>}. */
  public static final String SIGNATURE_V1_HEADER = "X-Callio-Signature";
  public static final Duration DEFAULT_TOLERANCE = Duration.ofSeconds(300);

  private static final Pattern LEGACY = Pattern.compile("^sha256=([0-9a-fA-F]{64})$");
  private static final Pattern V1 = Pattern.compile("^v1=([0-9a-fA-F]{64})$");

  private static byte[] hmac(String secret, byte[]... parts) {
    try {
      Mac m = Mac.getInstance("HmacSHA256");
      m.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
      for (byte[] p : parts) m.update(p);
      return m.doFinal();
    } catch (NoSuchAlgorithmException | InvalidKeyException e) {
      throw new IllegalStateException(e);
    }
  }

  private static String hex(byte[] b) {
    StringBuilder sb = new StringBuilder(b.length * 2);
    for (byte x : b) sb.append(Character.forDigit((x >> 4) & 0xf, 16)).append(Character.forDigit(x & 0xf, 16));
    return sb.toString();
  }

  private static byte[] unhex(String s) {
    byte[] out = new byte[s.length() / 2];
    for (int i = 0; i < out.length; i++) out[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
    return out;
  }

  private static void requireSecret(String secret) {
    if (secret == null || secret.isEmpty()) throw new IllegalArgumentException("Callio: the webhook secret is required");
  }

  /** Any comma-separated signature in {@code header} (rotation) matching {@code want}, compared in constant time. */
  private static boolean matches(Pattern p, String header, byte[] want) {
    if (header == null) return false;
    boolean ok = false;
    for (String part : header.split(",")) {
      Matcher m = p.matcher(part.trim());
      if (m.matches() && MessageDigest.isEqual(unhex(m.group(1).toLowerCase(Locale.ROOT)), want)) ok = true;
    }
    return ok;
  }

  /** The legacy {@code sha256=<hex>} value for this body. */
  public static String sign(byte[] rawBody, String secret) {
    requireSecret(secret);
    return "sha256=" + hex(hmac(secret, rawBody));
  }

  /** The {@code v1=<hex>} value Callio sends in X-Callio-Signature for this body and timestamp. */
  public static String signV1(byte[] rawBody, long timestamp, String secret) {
    requireSecret(secret);
    return "v1=" + hex(hmac(secret, (timestamp + ".").getBytes(StandardCharsets.UTF_8), rawBody));
  }

  /**
   * The legacy check: {@code signatureHeader} (X-NGX-Signature) is the HMAC-SHA256 of {@code rawBody}.
   * Constant-time; false for a missing or malformed header.
   *
   * @deprecated cannot detect a replayed request; use {@link #verifyRequest} with the request headers.
   */
  @Deprecated
  public static boolean verify(byte[] rawBody, String signatureHeader, String secret) {
    requireSecret(secret);
    return matches(LEGACY, signatureHeader, hmac(secret, rawBody));
  }

  /** @deprecated see {@link #verify(byte[], String, String)}. */
  @Deprecated
  public static boolean verify(String rawBody, String signatureHeader, String secret) {
    return verify(rawBody.getBytes(StandardCharsets.UTF_8), signatureHeader, secret);
  }

  /**
   * Checks a webhook request. Passes when X-Callio-Signature is valid for {@code X-Callio-Timestamp + "." +
   * rawBody} and the timestamp is within the tolerance; otherwise throws {@link WebhookVerificationException}
   * (status 401). A request without a timestamp is rejected unless {@code allowLegacy} is set (then
   * X-NGX-Signature is checked instead).
   *
   * @param header looks a header up by name, case-insensitively (e.g. {@code request::getHeader}).
   */
  @SuppressWarnings("deprecation")
  public static void verifyRequest(byte[] rawBody, Function<String, String> header, String secret, WebhookOptions options) {
    requireSecret(secret);
    Objects.requireNonNull(header, "header");
    WebhookOptions o = options == null ? new WebhookOptions() : options;
    String ts = trim(header.apply(TIMESTAMP_HEADER));
    if (ts == null || ts.isEmpty()) {
      if (!o.allowLegacy) {
        throw new WebhookVerificationException("Callio webhook: missing " + TIMESTAMP_HEADER + " (set allowLegacy to accept body-only signatures)", 401);
      }
      if (!verify(rawBody, header.apply(SIGNATURE_HEADER), secret)) {
        throw new WebhookVerificationException("Callio webhook: bad or missing " + SIGNATURE_HEADER, 401);
      }
      return;
    }
    long t;
    try {
      t = Long.parseLong(ts);
    } catch (NumberFormatException e) {
      throw new WebhookVerificationException("Callio webhook: malformed " + TIMESTAMP_HEADER, 401);
    }
    // The signature first, so a forged timestamp gets the same answer as a forged body.
    if (!matches(V1, header.apply(SIGNATURE_V1_HEADER), hmac(secret, (ts + ".").getBytes(StandardCharsets.UTF_8), rawBody))) {
      throw new WebhookVerificationException("Callio webhook: bad or missing " + SIGNATURE_V1_HEADER, 401);
    }
    long skew = Math.abs(o.clock.millis() / 1000 - t);
    if (skew > o.tolerance.getSeconds()) {
      throw new WebhookVerificationException("Callio webhook: timestamp outside the " + o.tolerance.getSeconds() + " s tolerance (replayed or clock skew)", 401);
    }
  }

  /** {@link #verifyRequest(byte[], Function, String, WebhookOptions)} with a header map (values: String or a collection). */
  public static void verifyRequest(byte[] rawBody, Map<String, ?> headers, String secret, WebhookOptions options) {
    verifyRequest(rawBody, lookup(headers), secret, options);
  }

  /** Verifies the request (see {@link #verifyRequest}) and parses the event. */
  public static WebhookEvent parseRequest(byte[] rawBody, Function<String, String> header, String secret, WebhookOptions options) {
    verifyRequest(rawBody, header, secret, options);
    return decode(rawBody);
  }

  public static WebhookEvent parseRequest(byte[] rawBody, Map<String, ?> headers, String secret, WebhookOptions options) {
    return parseRequest(rawBody, lookup(headers), secret, options);
  }

  /**
   * Verifies the legacy X-NGX-Signature and parses the event.
   *
   * @deprecated cannot detect a replayed request; use {@link #parseRequest} with the request headers.
   */
  @Deprecated
  public static WebhookEvent parse(byte[] rawBody, String signatureHeader, String secret) {
    if (!verify(rawBody, signatureHeader, secret)) {
      throw new WebhookVerificationException("Callio webhook: bad or missing " + SIGNATURE_HEADER, 401);
    }
    return decode(rawBody);
  }

  private static WebhookEvent decode(byte[] rawBody) {
    Object ev;
    try {
      ev = Json.parse(new String(rawBody, StandardCharsets.UTF_8));
    } catch (Json.JsonException e) {
      throw new WebhookVerificationException("Callio webhook: the body is not JSON", 400);
    }
    if (!(ev instanceof Map) || !(((Map<?, ?>) ev).get("type") instanceof String)) {
      throw new WebhookVerificationException("Callio webhook: no event type", 400);
    }
    return new WebhookEvent(Json.asMap(ev));
  }

  private static String trim(String s) { return s == null ? null : s.trim(); }

  private static Function<String, String> lookup(Map<String, ?> headers) {
    Objects.requireNonNull(headers, "headers");
    return name -> {
      for (Map.Entry<String, ?> e : headers.entrySet()) {
        if (e.getKey() == null || !e.getKey().equalsIgnoreCase(name)) continue;
        Object v = e.getValue();
        if (v instanceof Collection) {
          Collection<?> c = (Collection<?>) v;
          return c.isEmpty() ? null : String.valueOf(c.iterator().next());
        }
        if (v instanceof String[]) return ((String[]) v).length == 0 ? null : ((String[]) v)[0];
        return v == null ? null : String.valueOf(v);
      }
      return null;
    };
  }
}
