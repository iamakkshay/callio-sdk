package com.clarigoinfotech.callio;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpTimeoutException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.Arrays;
import java.util.Collection;
import java.util.Date;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ThreadLocalRandom;

/**
 * The HTTP layer: a timeout per attempt, and retries with exponential backoff for idempotent requests (GET,
 * HEAD, PUT, DELETE, OPTIONS) on 429, 5xx and network errors. Redirects are never followed. The API key only
 * ever goes into the Authorization header; it is never part of an error, a message, a URL or
 * {@link #toString()}.
 */
public final class CallioHttp {
  /** Decides the wait before retry {@code attempt + 1}; {@code retryAfter} is null when the server sent none. */
  @FunctionalInterface
  public interface Backoff {
    Duration delay(int attempt, Duration retryAfter);
  }

  /** Sleeps between retries (replaceable in tests). */
  @FunctionalInterface
  public interface Sleeper {
    void sleep(Duration d) throws InterruptedException;
  }

  private static final Set<String> IDEMPOTENT = new HashSet<>(Arrays.asList("GET", "HEAD", "PUT", "DELETE", "OPTIONS"));

  private final String baseUrl;
  private final Duration timeout;
  private final int maxRetries;
  private final String userAgent;
  private final char[] apiKey;
  private final Transport transport;
  private volatile Backoff backoff = CallioHttp::defaultBackoff;
  private volatile Sleeper sleeper = d -> Thread.sleep(d.toMillis());

  CallioHttp(String apiKey, String baseUrl, Duration timeout, int maxRetries, String userAgent, Transport transport) {
    this.apiKey = apiKey.toCharArray();
    this.baseUrl = baseUrl;
    this.timeout = timeout;
    this.maxRetries = maxRetries;
    this.userAgent = userAgent;
    this.transport = transport;
  }

  public String baseUrl() { return baseUrl; }
  public Duration timeout() { return timeout; }
  public int maxRetries() { return maxRetries; }
  public String userAgent() { return userAgent; }

  /** Replace the retry backoff (tests, custom policies). */
  public void setBackoff(Backoff b) { this.backoff = b; }

  /** Replace the sleep between retries (tests). */
  public void setSleeper(Sleeper s) { this.sleeper = s; }

  /** Never prints the key. */
  @Override public String toString() {
    return "CallioHttp{baseUrl=" + baseUrl + ", timeout=" + timeout + ", maxRetries=" + maxRetries + "}";
  }

  static Duration defaultBackoff(int attempt, Duration retryAfter) {
    if (retryAfter != null) return retryAfter.compareTo(Duration.ofSeconds(60)) > 0 ? Duration.ofSeconds(60) : retryAfter;
    double base = Math.min(8000, 500 * Math.pow(2, attempt));
    return Duration.ofMillis((long) (base * (0.5 + ThreadLocalRandom.current().nextDouble() / 2)));
  }

  // ---------------------------------------------------------------- encoding

  /** Like JavaScript's encodeURIComponent. */
  static String encodeSegment(String s) {
    return URLEncoder.encode(s, StandardCharsets.UTF_8).replace("+", "%20").replace("%21", "!").replace("%27", "'")
        .replace("%28", "(").replace("%29", ")").replace("%7E", "~");
  }

  /** "?k=v&…" in insertion order; null / "" / empty collections are left out; lists are comma-joined; dates are ISO. */
  public static String encodeQuery(Map<String, ?> query) {
    if (query == null || query.isEmpty()) return "";
    StringBuilder sb = new StringBuilder();
    for (Map.Entry<String, ?> e : query.entrySet()) {
      String v = queryValue(e.getValue());
      if (v == null) continue;
      sb.append(sb.length() == 0 ? '?' : '&')
          .append(URLEncoder.encode(e.getKey(), StandardCharsets.UTF_8)).append('=')
          .append(URLEncoder.encode(v, StandardCharsets.UTF_8));
    }
    return sb.toString();
  }

  private static String queryValue(Object v) {
    if (v == null) return null;
    if (v instanceof Collection) {
      Collection<?> c = (Collection<?>) v;
      if (c.isEmpty()) return null;
      StringBuilder sb = new StringBuilder();
      for (Object o : c) { if (sb.length() > 0) sb.append(','); sb.append(o); }
      return sb.toString();
    }
    if (v instanceof String[]) return queryValue(Arrays.asList((String[]) v));
    if (v instanceof Instant) return Json.ISO_MILLIS.format((Instant) v);
    if (v instanceof Date) return Json.ISO_MILLIS.format(((Date) v).toInstant());
    if (v instanceof OffsetDateTime) return Json.ISO_MILLIS.format(((OffsetDateTime) v).toInstant());
    if (v instanceof ZonedDateTime) return Json.ISO_MILLIS.format(((ZonedDateTime) v).toInstant());
    if (v instanceof LocalDate) return v.toString();
    String s = String.valueOf(v);
    return s.isEmpty() ? null : s;
  }

  /** Seconds, or an HTTP date; null when absent or unreadable. */
  public static Duration parseRetryAfter(String h) {
    if (h == null || h.trim().isEmpty()) return null;
    String t = h.trim();
    try {
      double n = Double.parseDouble(t);
      if (n >= 0 && !Double.isInfinite(n)) return Duration.ofMillis((long) (n * 1000));
      return null;
    } catch (NumberFormatException ignore) {
      // an HTTP date
    }
    try {
      Instant at = ZonedDateTime.parse(t, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant();
      long s = (long) Math.ceil((at.toEpochMilli() - System.currentTimeMillis()) / 1000.0);
      return Duration.ofSeconds(Math.max(0, s));
    } catch (DateTimeParseException e) {
      return null;
    }
  }

  // ---------------------------------------------------------------- requests

  /** Sends a request and returns the parsed JSON (Map, List, …, or null for an empty body). */
  public Object request(String method, String path, Map<String, ?> query, Object body) {
    Transport.Response res = send(method, path, query, body, false);
    try {
      return parseBody(readAll(res.body));
    } catch (IOException e) {
      throw new ConnectionException("Callio: the response was cut off (" + method + " " + path + ")", res.status, null, method + " " + path);
    }
  }

  /** {@link #request} for an object response. */
  public Map<String, Object> requestObject(String method, String path, Map<String, ?> query, Object body) {
    return Json.asMap(request(method, path, query, body));
  }

  /**
   * Sends a request and returns the open response on a 2xx, for streaming. The caller must close it. The
   * timeout covers getting the response headers.
   */
  public Transport.Response requestRaw(String method, String path, Map<String, ?> query) {
    return send(method, path, query, null, true);
  }

  private Transport.Response send(String method, String path, Map<String, ?> query, Object body, boolean stream) {
    method = method.toUpperCase(java.util.Locale.ROOT);
    String label = method + " " + path;
    URI uri;
    try {
      uri = URI.create(baseUrl + path + encodeQuery(query));
    } catch (IllegalArgumentException e) {
      throw new IllegalArgumentException("Callio: invalid request path " + path, e);
    }
    Map<String, String> headers = new LinkedHashMap<>();
    headers.put("Authorization", "Bearer " + new String(apiKey));
    headers.put("Accept", stream ? "*/*" : "application/json");
    headers.put("User-Agent", userAgent);
    byte[] payload = null;
    if (body != null) {
      headers.put("Content-Type", "application/json");
      payload = Json.stringify(body).getBytes(StandardCharsets.UTF_8);
    }
    boolean retryable = IDEMPOTENT.contains(method);

    for (int attempt = 0; ; attempt++) {
      Transport.Response res;
      try {
        res = transport.send(new Transport.Request(method, uri, headers, payload, timeout, stream));
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new ConnectionException("Callio: interrupted (" + label + ")", 0, null, label);
      } catch (IOException e) {
        CallioException err = e instanceof HttpTimeoutException
            ? new RequestTimeoutException("Callio: no response within " + timeout.toMillis() + " ms (" + label + ")", 0, null, label)
            : new ConnectionException("Callio: could not reach " + baseUrl + " (" + label + "): " + e, 0, null, label);
        if (retryable && attempt < maxRetries) { pause(backoff.delay(attempt, null), label); continue; }
        throw err;
      }

      int st = res.status;
      if (st >= 200 && st < 300 && stream) return res;
      if (st >= 300 && st < 400) {
        closeQuietly(res);
        String where = "another location";
        String loc = res.header("Location");
        if (loc != null) {
          try {
            URI l = URI.create(loc.trim());
            if (l.getHost() != null) where = l.getScheme() + "://" + l.getHost() + (l.getPort() > 0 ? ":" + l.getPort() : "");
          } catch (IllegalArgumentException ignore) {
            // keep the generic text
          }
        }
        throw new RedirectException("Callio: refusing to follow a redirect to " + where
            + " (the API key is never sent on a redirect); check the base URL", st, null, label);
      }
      if (st >= 200 && st < 300) return res;

      byte[] raw;
      try {
        raw = readAll(res.body);
      } catch (IOException e) {
        raw = new byte[0];
      } finally {
        closeQuietly(res);
      }
      Duration retryAfter = parseRetryAfter(res.header("Retry-After"));
      if (retryable && (st == 429 || st >= 500) && attempt < maxRetries) { pause(backoff.delay(attempt, retryAfter), label); continue; }
      Object parsed = parseBody(raw);
      String msg = "HTTP " + st;
      if (parsed instanceof Map && ((Map<?, ?>) parsed).get("error") instanceof String) msg = (String) ((Map<?, ?>) parsed).get("error");
      else if (parsed instanceof String && !((String) parsed).isEmpty()) msg = ((String) parsed).length() > 200 ? ((String) parsed).substring(0, 200) : (String) parsed;
      throw CallioException.forStatus(st, msg, parsed, label, retryAfter);
    }
  }

  private void pause(Duration d, String label) {
    try {
      if (!d.isZero() && !d.isNegative()) sleeper.sleep(d);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new ConnectionException("Callio: interrupted (" + label + ")", 0, null, label);
    }
  }

  private static void closeQuietly(Transport.Response r) {
    try { r.close(); } catch (IOException ignore) { /* nothing to do */ }
  }

  static byte[] readAll(InputStream in) throws IOException {
    try (InputStream i = in) {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      byte[] buf = new byte[16 * 1024];
      int n;
      while ((n = i.read(buf)) > 0) out.write(buf, 0, n);
      return out.toByteArray();
    }
  }

  static Object parseBody(byte[] raw) {
    if (raw == null || raw.length == 0) return null;
    String text = new String(raw, StandardCharsets.UTF_8);
    try {
      return Json.parse(text);
    } catch (Json.JsonException e) {
      return text;
    }
  }
}
