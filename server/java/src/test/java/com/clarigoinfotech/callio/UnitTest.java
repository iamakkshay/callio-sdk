package com.clarigoinfotech.callio;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.net.http.HttpClient;
import java.net.http.HttpTimeoutException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Deque;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/** Unit tests against a scripted {@link Transport}: no network (except two tests on a loopback server). */
class UnitTest {
  static final String KEY = "cio_abc123_s3cret-value";

  @FunctionalInterface
  interface Responder {
    Transport.Response respond(Transport.Request r) throws IOException, InterruptedException;
  }

  static final class Mock implements Transport {
    final Deque<Responder> responses = new ArrayDeque<>();
    final List<Transport.Request> calls = new ArrayList<>();

    Mock(Responder... rs) { responses.addAll(Arrays.asList(rs)); }

    @Override public Response send(Request r) throws IOException, InterruptedException {
      calls.add(r);
      Responder f = responses.poll();
      if (f == null) throw new AssertionError("unexpected request " + r.uri);
      return f.respond(r);
    }

    Object json(int i) { byte[] b = calls.get(i).body; return b == null ? null : Json.parse(new String(b, StandardCharsets.UTF_8)); }

    String url(int i) { return calls.get(i).uri.toString(); }

    String query(int i, String name) {
      String q = calls.get(i).uri.getRawQuery();
      for (String kv : q.split("&")) {
        String[] p = kv.split("=", 2);
        if (p[0].equals(name)) return URLDecoder.decode(p[1], StandardCharsets.UTF_8);
      }
      return null;
    }
  }

  static Responder json(int status, Object body, String... headers) {
    return r -> {
      Map<String, List<String>> h = new HashMap<>();
      h.put("content-type", List.of("application/json"));
      for (int i = 0; i + 1 < headers.length; i += 2) h.put(headers[i], List.of(headers[i + 1]));
      byte[] b = body == null ? new byte[0] : Json.stringify(body).getBytes(StandardCharsets.UTF_8);
      return new Transport.Response(status, h, new ByteArrayInputStream(b));
    };
  }

  static Map<String, Object> obj(Object... kv) {
    Map<String, Object> m = new LinkedHashMap<>();
    for (int i = 0; i < kv.length; i += 2) m.put((String) kv[i], kv[i + 1]);
    return m;
  }

  static Callio client(Mock m) { return client(m, 2); }

  static Callio client(Mock m, int retries) {
    Callio c = Callio.builder().apiKey(KEY).baseUrl("https://api.example.test/").transport(m).maxRetries(retries).build();
    c.http().setSleeper(d -> { });
    return c;
  }

  @Test void sendsBearerJsonAndUserAgent() {
    Mock m = new Mock(json(201, obj("user", obj("username", "u1", "extension", "1001"))));
    CreatedUser u = client(m).users().create(new CreateUserParams("u1").displayName("U One").userType("customer"));
    assertEquals("1001", u.extension());
    Transport.Request r = m.calls.get(0);
    assertEquals("https://api.example.test/api/v1/users", r.uri.toString());
    assertEquals("POST", r.method);
    assertEquals("Bearer " + KEY, r.headers.get("Authorization"));
    assertEquals("application/json", r.headers.get("Content-Type"));
    assertTrue(r.headers.get("User-Agent").matches("^callio-server-java/" + Version.VERSION.replace(".", "\\.") + " java/.*"), r.headers.get("User-Agent"));
    assertEquals(obj("username", "u1", "displayName", "U One", "userType", "customer"), m.json(0));
  }

  @Test void queryAndPathEncoding() {
    Mock m = new Mock(json(200, obj("users", List.of())), json(200, obj("events", List.of(), "next", 5)), json(200, obj("user", obj())), json(200, obj("recordings", List.of())));
    Callio c = client(m);
    c.users().list(new ListUsersParams().q("sa ra").type("agent").status(null));
    c.events().list(new ListEventsParams().after(5).types("call.", "chat."));
    c.users().get("a/b@c");
    c.recordings().list(new ListRecordingsParams().from(Instant.parse("2026-01-01T00:00:00Z")).minDuration(10));
    assertEquals("https://api.example.test/api/v1/users?q=sa+ra&type=agent", m.url(0));
    assertEquals("https://api.example.test/api/v1/events?after=5&types=call.%2Cchat.", m.url(1));
    assertEquals("https://api.example.test/api/v1/users/a%2Fb%40c", m.url(2));
    assertEquals("https://api.example.test/api/v1/recordings?from=2026-01-01T00%3A00%3A00.000Z&minDuration=10", m.url(3));
  }

  @Test void statusesMapToTypedExceptions() {
    Object[][] cases = {{400, ValidationException.class}, {401, AuthenticationException.class}, {403, PermissionDeniedException.class},
        {404, NotFoundException.class}, {409, ConflictException.class}, {410, GoneException.class}, {500, ServerException.class}, {418, CallioException.class}};
    for (Object[] tc : cases) {
      int status = (Integer) tc[0];
      Mock m = new Mock(json(status, obj("error", "reason " + status)));
      CallioException e = assertThrows(CallioException.class, () -> client(m, 0).orders().get("X"));
      assertEquals(tc[1], e.getClass(), status + " → " + e.getClass());
      assertEquals(status, e.status());
      assertEquals("reason " + status, e.getMessage());
      assertEquals("GET /api/v1/orders/X", e.request());
      assertFalse(e.toString().contains(KEY));
    }
  }

  @Test void ipAllowList403() {
    Mock m = new Mock(json(403, obj("error", "this network (203.0.113.9) is not allowed to use this organisation's API")));
    PermissionDeniedException e = assertThrows(PermissionDeniedException.class, () -> client(m).users().list());
    assertTrue(e.getMessage().contains("not allowed"));
  }

  @Test void getRetriesHonouringRetryAfter() {
    Mock m = new Mock(json(429, obj("error", "slow down"), "retry-after", "2"), json(503, obj("error", "busy")), json(200, obj("orders", List.of(obj("id", "A")))));
    Callio c = client(m);
    List<String> waits = new ArrayList<>();
    c.http().setBackoff((attempt, ra) -> { waits.add(attempt + ":" + ra); return Duration.ZERO; });
    List<Order> orders = c.orders().list();
    assertEquals("A", orders.get(0).id());
    assertEquals(3, m.calls.size());
    assertEquals(List.of("0:PT2S", "1:null"), waits);
  }

  @Test void givesUpWithRateLimitRetryAfter() {
    Mock m = new Mock(json(429, obj("error", "a"), "retry-after", "7"), json(429, obj("error", "b"), "retry-after", "7"));
    RateLimitException e = assertThrows(RateLimitException.class, () -> client(m, 1).cdr().list());
    assertEquals(Duration.ofSeconds(7), e.retryAfter().orElseThrow());
    assertEquals(429, e.status());
    assertEquals(2, m.calls.size());
  }

  @Test void postAndPatchNeverRetried() {
    Mock m1 = new Mock(json(503, obj("error", "busy")));
    assertThrows(ServerException.class, () -> client(m1).orders().create(new CreateOrderParams("O1", "c")));
    assertEquals(1, m1.calls.size());
    Mock m2 = new Mock(json(429, obj("error", "slow"), "retry-after", "1"));
    assertThrows(RateLimitException.class, () -> client(m2).orders().close("O1"));
    assertEquals(1, m2.calls.size());
  }

  @Test void networkErrorsRetriedForGet() {
    Responder boom = r -> { throw new IOException("connection refused"); };
    Mock m = new Mock(boom, boom, boom);
    ConnectionException e = assertThrows(ConnectionException.class, () -> client(m).groups().list());
    assertFalse(e instanceof RequestTimeoutException);
    assertEquals(0, e.status());
    assertFalse(e.getMessage().contains(KEY));
    assertEquals(3, m.calls.size());
  }

  @Test void timeoutFromTransport() {
    Mock m = new Mock(r -> { throw new HttpTimeoutException("timed out"); });
    RequestTimeoutException e = assertThrows(RequestTimeoutException.class, () -> client(m, 0).users().get("x"));
    assertInstanceOf(ConnectionException.class, e);
  }

  @Test void forUserCreatesThenIssues() {
    Mock m = new Mock(json(201, obj("user", obj("username", "c1"))), json(200, obj("token", "jwt", "userType", "customer", "expiresAt", "later")));
    UserToken t = client(m).tokens().forUser("c1", new ForUserOptions().displayName("C").userType("customer").ttlSec(600));
    assertEquals(obj("token", "jwt", "userType", "customer", "expiresAt", "later", "created", true), t.raw());
    assertTrue(t.created());
    assertEquals(obj("username", "c1", "displayName", "C", "userType", "customer"), m.json(0));
    assertEquals(obj("username", "c1", "ttlSec", 600L), m.json(1));
  }

  @Test void forUser409MeansExists() {
    Mock m = new Mock(json(409, obj("error", "user exists")), json(200, obj("token", "jwt", "userType", "agent", "expiresAt", "x")));
    UserToken t = client(m).tokens().forUser("a1", new ForUserOptions().userType("agent"));
    assertFalse(t.created());
    assertEquals("jwt", t.token());
  }

  @Test void forUserPropagatesOtherErrors() {
    Mock m = new Mock(json(403, obj("error", "seat quota reached")));
    assertThrows(PermissionDeniedException.class, () -> client(m).tokens().forUser("a1"));
    assertEquals(1, m.calls.size());
  }

  @Test void orderHelpersPatch() {
    Map<String, Object> o = obj("order", obj("id", "O1"));
    Mock m = new Mock(json(200, o), json(200, o), json(200, o), json(200, o));
    Callio c = client(m);
    c.orders().assign("O1", "drv");
    c.orders().assign("O1", null);
    c.orders().close("O1");
    c.orders().reopen("O1");
    List<Object> got = new ArrayList<>();
    for (int i = 0; i < 4; i++) got.add(Arrays.asList(m.calls.get(i).method, m.json(i)));
    Map<String, Object> unassign = new LinkedHashMap<>();
    unassign.put("agent", null);
    assertEquals(List.of(Arrays.asList("PATCH", obj("agent", "drv")), Arrays.asList("PATCH", unassign),
        Arrays.asList("PATCH", obj("status", "closed")), Arrays.asList("PATCH", obj("status", "active"))), got);
  }

  @Test void usersDisableEnableAndNullableFields() {
    Map<String, Object> u = obj("user", obj("username", "u1"));
    Mock m = new Mock(json(200, u), json(200, u), json(200, u));
    Callio c = client(m);
    c.users().disable("u1");
    c.users().enable("u1");
    c.users().update("u1", new UpdateUserParams().displayName("N").segment(null));
    assertEquals(obj("disabled", true), m.json(0));
    assertEquals(obj("disabled", false), m.json(1));
    Map<String, Object> want = new LinkedHashMap<>();
    want.put("displayName", "N");
    want.put("segment", null);
    assertEquals(want, m.json(2));
  }

  @Test void usersDeleteSendsReason() {
    Mock m = new Mock(json(200, obj("ok", true, "alias", "erased-1", "removed", obj(), "recordingsKeptOnLegalHold", List.of())));
    ErasureResult r = client(m).users().delete("u1", "customer asked");
    assertEquals("erased-1", r.alias());
    assertEquals("DELETE", m.calls.get(0).method);
    assertEquals(obj("reason", "customer asked"), m.json(0));
  }

  @Test void recordingAudioStreamsAndDownloads(@TempDir Path dir) throws IOException {
    byte[] bytes = {79, 103, 103, 83, 1, 2, 3};
    Responder audio = r -> new Transport.Response(200, Map.of("Content-Type", List.of("audio/ogg"), "Content-Length", List.of("7")), new ByteArrayInputStream(bytes));
    Mock m = new Mock(audio, audio, audio);
    Callio c = client(m);
    try (RecordingAudio a = c.recordings().audio("rec-1", "QA review — طلب")) {
      assertEquals("audio/ogg", a.contentType());
      assertEquals(7L, a.contentLength().getAsLong());
      assertArrayEquals(bytes, a.body().readAllBytes());
    }
    assertEquals("QA review — طلب", m.query(0, "reason"));
    assertEquals("*/*", m.calls.get(0).headers.get("Accept"));
    assertTrue(m.calls.get(0).stream);
    Path file = dir.resolve("a.ogg");
    assertEquals(7L, c.recordings().download("rec-1", file, "dispute 123"));
    assertArrayEquals(bytes, Files.readAllBytes(file));
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    assertEquals(7L, c.recordings().download("rec-1", out, "dispute 123"));
    assertArrayEquals(bytes, out.toByteArray());
  }

  @Test void recordingAudioRequiresReasonAndMaps410() {
    Mock m = new Mock(json(410, obj("error", "this recording was deleted")));
    Callio c = client(m);
    assertThrows(IllegalArgumentException.class, () -> c.recordings().audio("r", "no"));
    assertThrows(IllegalArgumentException.class, () -> c.recordings().transcript("r", "    "));
    assertThrows(GoneException.class, () -> c.recordings().audio("r", "audit check"));
    assertEquals(1, m.calls.size());
  }

  @Test void rejectsDotPathSegments() {
    Mock m = new Mock();
    Callio c = client(m);
    for (String id : new String[] {"", ".", "..", null}) {
      assertThrows(IllegalArgumentException.class, () -> c.users().get(id));
      assertThrows(IllegalArgumentException.class, () -> c.orders().close(id));
      assertThrows(IllegalArgumentException.class, () -> c.groups().delete(id));
    }
    assertEquals(0, m.calls.size());
  }

  @Test void transcript() {
    Mock m = new Mock(json(200, obj("transcript", obj("text", "hello", "language", "en", "segments", List.of(obj("start", 0, "end", 1.5, "text", "hello"))))));
    Transcript t = client(m).recordings().transcript("r1", "QA review");
    assertEquals("hello", t.text());
    assertEquals(1.5, t.segments().get(0).get("end"));
    assertEquals("QA review", m.query(0, "reason"));
  }

  @Test void eventsIteratePagesUntilCaughtUp() {
    Mock m = new Mock(json(200, obj("events", List.of(obj("id", 1), obj("id", 2)), "next", 2)), json(200, obj("events", List.of(obj("id", 3)), "next", 3)), json(200, obj("events", List.of(), "next", 3)));
    List<Long> ids = new ArrayList<>();
    for (CallioEvent e : client(m).events().iterate(new ListEventsParams().limit(2))) ids.add(e.id());
    assertEquals(List.of(1L, 2L, 3L), ids);
    assertEquals(List.of("0", "2", "3"), List.of(m.query(0, "after"), m.query(1, "after"), m.query(2, "after")));
  }

  @Test void rawRequestEscapeHatch() {
    Mock m = new Mock(json(200, obj("hello", "world")));
    Map<String, Object> r = client(m).http().requestObject("GET", "/api/v1/whatever", Map.of("x", 1), null);
    assertEquals("world", r.get("hello"));
    assertEquals("https://api.example.test/api/v1/whatever?x=1", m.url(0));
  }

  @Test void keyNeverInToString() {
    Callio c = client(new Mock());
    assertFalse(c.toString().contains(KEY));
    assertFalse(c.http().toString().contains(KEY));
    assertFalse(Callio.builder().apiKey(KEY).toString().contains(KEY));
  }

  @Test void builderValidatesAndRequiresHttps() {
    // CALLIO_API_KEY / CALLIO_BASE_URL are not set in the test environment.
    if (System.getenv("CALLIO_API_KEY") == null) {
      assertTrue(assertThrows(CallioException.class, () -> Callio.builder().baseUrl("https://x").build()).getMessage().contains("apiKey is required"));
    }
    if (System.getenv("CALLIO_BASE_URL") == null) {
      assertTrue(assertThrows(CallioException.class, () -> Callio.builder().apiKey(KEY).build()).getMessage().contains("baseUrl is required"));
    }
    assertTrue(assertThrows(CallioException.class, () -> Callio.builder().apiKey(KEY).baseUrl("api.example.sa").build()).getMessage().contains("https"));
    assertTrue(assertThrows(CallioException.class, () -> Callio.builder().apiKey(KEY).baseUrl("http://localhost:8080").build()).getMessage().contains("allowInsecure"));
    assertEquals("http://localhost:8080", Callio.builder().apiKey(KEY).baseUrl("http://localhost:8080/").allowInsecure(true).build().http().baseUrl());
    assertEquals("https://api.example.test", Callio.builder().apiKey(KEY).baseUrl("https://api.example.test//").build().http().baseUrl());
  }

  @Test void redirectsAreRefused() {
    Mock m = new Mock(json(302, null, "Location", "https://evil.example/steal?x=1"), json(200, obj("users", List.of())));
    RedirectException e = assertThrows(RedirectException.class, () -> client(m).users().list());
    assertEquals(302, e.status());
    assertTrue(e.getMessage().contains("https://evil.example"), e.getMessage());
    assertEquals(1, m.calls.size());
    assertThrows(IllegalArgumentException.class, () -> new JdkTransport(HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NORMAL).build()));
  }

  @Test void jdkTransportDoesNotFollowRedirectsAndTimesOut() throws IOException {
    HttpServer evil = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    AtomicInteger evilHits = new AtomicInteger();
    evil.createContext("/", x -> { evilHits.incrementAndGet(); x.sendResponseHeaders(200, -1); x.close(); });
    evil.start();
    HttpServer s = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    s.createContext("/api/v1/users", x -> {
      x.getResponseHeaders().add("Location", "http://127.0.0.1:" + evil.getAddress().getPort() + "/api/v1/users");
      x.sendResponseHeaders(307, -1);
      x.close();
    });
    s.createContext("/api/v1/groups", x -> {
      try { Thread.sleep(4000); } catch (InterruptedException ignore) { /* stop */ }
      x.sendResponseHeaders(200, -1);
      x.close();
    });
    s.createContext("/api/v1/recordings/r1/audio", x -> {
      byte[] b = "OggS-stream".getBytes(StandardCharsets.UTF_8);
      x.getResponseHeaders().add("Content-Type", "audio/ogg");
      x.sendResponseHeaders(200, b.length);
      try (OutputStream o = x.getResponseBody()) { o.write(b); }
    });
    s.setExecutor(java.util.concurrent.Executors.newCachedThreadPool());
    s.start();
    try {
      Callio c = Callio.builder().apiKey(KEY).baseUrl("http://127.0.0.1:" + s.getAddress().getPort()).allowInsecure(true)
          .timeout(Duration.ofMillis(1500)).maxRetries(0).build();
      assertThrows(RedirectException.class, () -> c.users().list());
      assertEquals(0, evilHits.get());
      assertThrows(RequestTimeoutException.class, () -> c.groups().list());
      try (RecordingAudio a = c.recordings().audio("r1", "QA review"); InputStream in = a.body()) {
        assertEquals("OggS-stream", new String(in.readAllBytes(), StandardCharsets.UTF_8));
      }
    } finally {
      s.stop(0);
      evil.stop(0);
    }
  }

  @Test void parseRetryAfter() {
    assertEquals(Duration.ofSeconds(3), CallioHttp.parseRetryAfter("3"));
    String date = java.time.format.DateTimeFormatter.RFC_1123_DATE_TIME.format(java.time.ZonedDateTime.now(ZoneOffset.UTC).plusSeconds(5));
    long s = CallioHttp.parseRetryAfter(date).getSeconds();
    assertTrue(s >= 4 && s <= 6, String.valueOf(s));
    assertNull(CallioHttp.parseRetryAfter(""));
    assertNull(CallioHttp.parseRetryAfter("soon"));
    assertNull(CallioHttp.parseRetryAfter("-1"));
  }

  @Test void jsonCodecRoundTrips() {
    String src = "{\"a\":[1,2.5,-3e2,true,false,null],\"s\":\"q\\\"\\\\\\n\\u00e9\\u0001 ☎\",\"big\":12345678901234567890,\"o\":{}}";
    Object v = Json.parse(src);
    Map<String, Object> m = Json.asMap(v);
    assertEquals(Arrays.asList(1L, 2.5, -300.0, true, false, null), m.get("a"));
    assertEquals("q\"\\\né\u0001 ☎", m.get("s"));
    assertEquals(new java.math.BigInteger("12345678901234567890"), m.get("big"));
    assertEquals(Json.stringify(v), Json.stringify(Json.parse(Json.stringify(v))));
    assertEquals("{\"x\":[1,2.5,\"\\u0001\"],\"n\":null}", Json.stringify(Json.parse("{\"x\":[1,2.5,\"\\u0001\"],\"n\":null}")));
    for (String bad : new String[] {"", "{", "[1,]", "{\"a\" 1}", "tru", "\"x", "1 2", "{\"a\":1,}"}) {
      assertThrows(Json.JsonException.class, () -> Json.parse(bad), bad);
    }
  }

  // ---------------------------------------------------------------- webhooks

  static final String SECRET = "whsec_test";
  static final byte[] BODY = "{\"tenantId\":\"lab\",\"type\":\"order.assigned\",\"order\":{\"id\":\"O1\",\"agent\":\"drv\"},\"by\":\"apikey:abc\",\"at\":\"2026-01-01T00:00:00Z\"}".getBytes(StandardCharsets.UTF_8);
  static final byte[] BODY_V1 = "{\"id\":\"evt_01\",\"tenantId\":\"lab\",\"type\":\"recording.ready\",\"recordingId\":\"rec-9\",\"durationSec\":42,\"at\":\"2026-01-01T00:00:00Z\"}".getBytes(StandardCharsets.UTF_8);

  static String hmacHex(String secret, byte[] data) throws Exception {
    javax.crypto.Mac mac = javax.crypto.Mac.getInstance("HmacSHA256");
    mac.init(new javax.crypto.spec.SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
    StringBuilder sb = new StringBuilder();
    for (byte b : mac.doFinal(data)) sb.append(String.format("%02x", b));
    return sb.toString();
  }

  static Map<String, String> v1Headers(byte[] body, long ts, String secret) {
    Map<String, String> h = new HashMap<>();
    h.put("x-callio-timestamp", String.valueOf(ts));
    h.put("x-callio-signature", Webhooks.signV1(body, ts, secret));
    h.put("x-ngx-signature", Webhooks.sign(body, secret));
    return h;
  }

  @SuppressWarnings("deprecation")
  @Test void legacyVerifyAccepts() throws Exception {
    String sig = "sha256=" + hmacHex(SECRET, BODY);
    assertEquals(sig, Webhooks.sign(BODY, SECRET));
    assertTrue(Webhooks.verify(BODY, sig, SECRET));
    assertTrue(Webhooks.verify(new String(BODY, StandardCharsets.UTF_8), "  " + sig + " ", SECRET));
    assertTrue(Webhooks.verify(BODY, "sha256=" + sig.substring(7).toUpperCase(), SECRET));
  }

  @SuppressWarnings("deprecation")
  @Test void legacyVerifyRejects() {
    String sig = Webhooks.sign(BODY, SECRET);
    byte[] tampered = Arrays.copyOf(BODY, BODY.length + 1);
    tampered[BODY.length] = ' ';
    assertFalse(Webhooks.verify(tampered, sig, SECRET));
    assertFalse(Webhooks.verify(BODY, sig, "other"));
    for (String h : new String[] {null, "", "sha256=", "sha256=zz", sig.substring(7), "sha1=" + sig.substring(7), sig + "00"}) {
      assertFalse(Webhooks.verify(BODY, h, SECRET), String.valueOf(h));
    }
    assertThrows(IllegalArgumentException.class, () -> Webhooks.verify(BODY, sig, ""));
  }

  @SuppressWarnings("deprecation")
  @Test void legacyParse() {
    WebhookEvent ev = Webhooks.parse(BODY, Webhooks.sign(BODY, SECRET), SECRET);
    assertTrue(ev.isOrderEvent());
    assertEquals("drv", ev.order().agent());
    assertEquals("apikey:abc", ev.by());
    assertThrows(WebhookVerificationException.class, () -> Webhooks.parse(BODY, "sha256=" + "0".repeat(64), SECRET));
    byte[] notJson = "nope".getBytes(StandardCharsets.UTF_8);
    assertEquals(400, assertThrows(WebhookVerificationException.class, () -> Webhooks.parse(notJson, Webhooks.sign(notJson, SECRET), SECRET)).status());
  }

  @Test void verifyRequestV1() throws Exception {
    long now = Instant.now().getEpochSecond();
    Map<String, String> h = v1Headers(BODY_V1, now, SECRET);
    byte[] signed = (now + "." + new String(BODY_V1, StandardCharsets.UTF_8)).getBytes(StandardCharsets.UTF_8);
    assertEquals("v1=" + hmacHex(SECRET, signed), h.get("x-callio-signature"));
    Webhooks.verifyRequest(BODY_V1, h, SECRET, null);
    WebhookEvent ev = Webhooks.parseRequest(BODY_V1, h, SECRET, null);
    assertEquals("evt_01", ev.id());
    assertTrue(ev.isRecordingReady());
    assertEquals("rec-9", ev.recordingId());
    // Header lookup function (e.g. HttpServletRequest::getHeader) and multi-valued maps.
    Webhooks.verifyRequest(BODY_V1, name -> h.get(name.toLowerCase()), SECRET, null);
    Map<String, List<String>> multi = new HashMap<>();
    h.forEach((k, v) -> multi.put(k.toUpperCase(), List.of(v)));
    Webhooks.verifyRequest(BODY_V1, multi, SECRET, null);
    // Rotation: any of several v1 signatures may match.
    Map<String, String> rot = new HashMap<>(h);
    rot.put("x-callio-signature", "v1=" + "0".repeat(64) + ", " + h.get("x-callio-signature"));
    Webhooks.verifyRequest(BODY_V1, rot, SECRET, null);
  }

  @Test void verifyRequestRejects() {
    long now = Instant.now().getEpochSecond();
    byte[] tampered = Arrays.copyOf(BODY_V1, BODY_V1.length + 1);
    tampered[BODY_V1.length] = ' ';
    List<Object[]> bad = new ArrayList<>();
    bad.add(new Object[] {"tampered", tampered, v1Headers(BODY_V1, now, SECRET), null});
    bad.add(new Object[] {"wrong secret", BODY_V1, v1Headers(BODY_V1, now, "other"), null});
    bad.add(new Object[] {"stale (replay)", BODY_V1, v1Headers(BODY_V1, now - 301, SECRET), null});
    bad.add(new Object[] {"future", BODY_V1, v1Headers(BODY_V1, now + 301, SECRET), null});
    Map<String, String> swapped = v1Headers(BODY_V1, now, SECRET);
    swapped.put("x-callio-timestamp", String.valueOf(now + 1));
    bad.add(new Object[] {"swapped timestamp", BODY_V1, swapped, null});
    Map<String, String> malformed = v1Headers(BODY_V1, now, SECRET);
    malformed.put("x-callio-timestamp", "yesterday");
    bad.add(new Object[] {"malformed timestamp", BODY_V1, malformed, null});
    Map<String, String> noV1 = v1Headers(BODY_V1, now, SECRET);
    noV1.remove("x-callio-signature");
    bad.add(new Object[] {"timestamp without v1", BODY_V1, noV1, new WebhookOptions().allowLegacy(true)});
    Map<String, String> legacyOnly = v1Headers(BODY_V1, now, SECRET);
    legacyOnly.remove("x-callio-timestamp");
    bad.add(new Object[] {"legacy only, not allowed", BODY_V1, legacyOnly, null});
    bad.add(new Object[] {"custom tolerance", BODY_V1, v1Headers(BODY_V1, now - 60, SECRET), new WebhookOptions().tolerance(Duration.ofSeconds(30))});
    bad.add(new Object[] {"clock", BODY_V1, v1Headers(BODY_V1, now, SECRET), new WebhookOptions().clock(Clock.fixed(Instant.ofEpochSecond(now + 1000), ZoneOffset.UTC))});
    for (Object[] b : bad) {
      @SuppressWarnings("unchecked") Map<String, String> hh = (Map<String, String>) b[2];
      WebhookVerificationException e = assertThrows(WebhookVerificationException.class,
          () -> Webhooks.verifyRequest((byte[]) b[1], hh, SECRET, (WebhookOptions) b[3]), (String) b[0]);
      assertEquals(401, e.status(), (String) b[0]);
      assertThrows(WebhookVerificationException.class, () -> Webhooks.parseRequest((byte[]) b[1], hh, SECRET, (WebhookOptions) b[3]), (String) b[0]);
    }
    Webhooks.verifyRequest(BODY_V1, v1Headers(BODY_V1, now - 600, SECRET), SECRET, new WebhookOptions().tolerance(Duration.ofMinutes(15)));
    assertThrows(IllegalArgumentException.class, () -> Webhooks.verifyRequest(BODY_V1, v1Headers(BODY_V1, now, SECRET), "", null));
  }

  @Test void verifyRequestAllowLegacy() {
    Map<String, String> h = Collections.singletonMap("X-NGX-Signature", Webhooks.sign(BODY_V1, SECRET));
    Webhooks.verifyRequest(BODY_V1, h, SECRET, new WebhookOptions().allowLegacy(true));
    Map<String, String> wrong = Collections.singletonMap("X-NGX-Signature", Webhooks.sign(BODY_V1, "other"));
    assertThrows(WebhookVerificationException.class, () -> Webhooks.verifyRequest(BODY_V1, wrong, SECRET, new WebhookOptions().allowLegacy(true)));
  }

  @Test void versionMatchesPom() throws IOException {
    String pom = new String(Files.readAllBytes(Path.of("pom.xml")), StandardCharsets.UTF_8);
    assertTrue(pom.contains("<artifactId>callio-server</artifactId>\n  <version>" + Version.VERSION + "</version>"));
  }
}
