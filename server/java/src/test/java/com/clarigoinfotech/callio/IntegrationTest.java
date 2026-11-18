package com.clarigoinfotech.callio;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;

/**
 * Integration test against a running Callio stack. It signs in to the admin API, creates a temporary API key
 * for the tenant, exercises the SDK, and cleans up everything it made (users, order, group, the key). Nothing
 * secret lives in this file; pass it in the environment:
 * <pre>
 * CALLIO_ADMIN_PASS=… [CALLIO_ADMIN_USER=admin] [CALLIO_URL=http://localhost:8080] [CALLIO_TENANT=lab] mvn test -Pintegration
 * </pre>
 * CALLIO_IT_AUDIO=1 also downloads one recording (that read is written to the recording's access trail).
 * Skipped when CALLIO_ADMIN_PASS is not set.
 */
@Tag("integration")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class IntegrationTest {
  static final String URL = env("CALLIO_URL", "http://localhost:8080").replaceAll("/+$", "");
  static final String TENANT = env("CALLIO_TENANT", "lab");
  static final String PASS = System.getenv("CALLIO_ADMIN_PASS");
  static final String RUN = Long.toString(System.currentTimeMillis(), 36);
  static final String CUST = "sdk-it-java-c-" + RUN, AGENT = "sdk-it-java-a-" + RUN, ORDER = "SDK-IT-JAVA-" + RUN, GROUP = "sdk-it-java-g-" + RUN;

  static String admin;
  static Map<String, Object> key;
  static Callio callio;
  static final List<String> users = new ArrayList<>();
  static boolean groupMade, orderMade;

  static String env(String k, String d) { String v = System.getenv(k); return v == null || v.isEmpty() ? d : v; }

  static Map<String, Object> adminReq(String method, String path, Object body) throws Exception {
    HttpRequest.Builder b = HttpRequest.newBuilder(URI.create(URL + path)).timeout(Duration.ofSeconds(15)).header("Content-Type", "application/json")
        .method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(Json.stringify(body)));
    if (admin != null) b.header("Authorization", "Bearer " + admin);
    HttpResponse<String> r = HttpClient.newHttpClient().send(b.build(), HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
    Map<String, Object> j = r.body().isEmpty() ? Map.of() : Json.asMap(Json.parse(r.body()));
    if (r.statusCode() >= 300) throw new AssertionError(method + " " + path + " → " + r.statusCode() + " " + j.get("error"));
    return j;
  }

  @BeforeAll static void setUp() throws Exception {
    assumeTrue(PASS != null && !PASS.isEmpty(), "set CALLIO_ADMIN_PASS (and optionally CALLIO_ADMIN_USER, CALLIO_URL, CALLIO_TENANT)");
    admin = (String) adminReq("POST", "/api/admin/login", Map.of("username", env("CALLIO_ADMIN_USER", "admin"), "password", PASS)).get("token");
    assertNotNull(admin, "admin login (MFA-enabled admins are not supported by this test)");
    key = Json.asMap(adminReq("POST", "/api/admin/tenants/" + TENANT + "/api-keys", Map.of("name", "sdk-it-java-" + RUN)).get("key"));
    callio = Callio.builder().apiKey((String) key.get("key")).baseUrl(URL).allowInsecure(URL.startsWith("http://")).userAgent("callio-it").build();
  }

  @AfterAll static void tearDown() throws Exception {
    if (callio == null) return;
    try {
      if (groupMade) quiet(() -> callio.groups().delete(GROUP));
      if (orderMade) quiet(() -> callio.orders().close(ORDER)); // orders can't be deleted; erasing the users pseudonymises it
      for (String u : users) quiet(() -> callio.users().delete(u, "SDK integration test cleanup"));
    } finally {
      adminReq("DELETE", "/api/admin/tenants/" + TENANT + "/api-keys/" + key.get("id"), null);
    }
    assertThrows(AuthenticationException.class, () -> callio.users().list(new ListUsersParams().limit(1)), "the revoked key still works");
  }

  static void quiet(Runnable r) { try { r.run(); } catch (RuntimeException ignore) { /* best effort */ } }

  @Test @Order(1) void users() {
    CreatedUser c = callio.users().create(new CreateUserParams(CUST).displayName("SDK IT Customer").userType("customer"));
    users.add(CUST);
    assertEquals(CUST, c.username());
    assertEquals("customer", c.userType());
    assertNotNull(c.extension());
    assertNotNull(c.initialPassword(), "a random password is returned once");
    assertThrows(ConflictException.class, () -> callio.users().create(CUST));
    assertThrows(ValidationException.class, () -> callio.users().create("bad name!"));
    assertThrows(NotFoundException.class, () -> callio.users().get(CUST + "-missing"));

    assertEquals("SDK IT Customer", callio.users().get(CUST).displayName());
    User u = callio.users().update(CUST, new UpdateUserParams().displayName("SDK IT Renamed").segment("sdk-it"));
    assertEquals("SDK IT Renamed", u.displayName());
    assertEquals("sdk-it", u.segment());
    assertTrue(callio.users().list(new ListUsersParams().q(CUST)).stream().anyMatch(x -> x.username().equals(CUST)));

    Token t = callio.tokens().create(CUST, 120);
    assertEquals(3, t.token().split("\\.").length);
    assertEquals("customer", t.userType());
    assertTrue(Instant.parse(t.expiresAt()).isAfter(Instant.now()));
    assertEquals(Boolean.TRUE, callio.users().signOut(CUST).get("ok"));
    assertNotNull(callio.users().export(CUST).get("exportedAt"));
  }

  @Test @Order(2) void forUser() {
    UserToken first = callio.tokens().forUser(AGENT, new ForUserOptions().displayName("SDK IT Agent").userType("agent").ttlSec(60));
    users.add(AGENT);
    assertTrue(first.created());
    assertEquals("agent", first.userType());
    UserToken again = callio.tokens().forUser(AGENT, new ForUserOptions().userType("agent"));
    assertFalse(again.created());
    assertNotNull(again.token());
    callio.users().disable(AGENT);
    assertEquals(403, assertThrows(CallioException.class, () -> callio.tokens().create(AGENT)).status());
    callio.users().enable(AGENT);
  }

  @Test @Order(3) void ordersAndEvents() {
    long before = callio.events().list(new ListEventsParams().after(0).limit(1)).next();
    assertThrows(ValidationException.class, () -> callio.orders().create(new CreateOrderParams(ORDER, AGENT))); // wrong user type
    com.clarigoinfotech.callio.Order o = callio.orders().create(new CreateOrderParams(ORDER, CUST).label("SDK integration test"));
    orderMade = true;
    assertEquals("active", o.status());
    assertNull(o.agent());
    assertThrows(ConflictException.class, () -> callio.orders().create(new CreateOrderParams(ORDER, CUST)));
    assertEquals("SDK integration test", callio.orders().get(ORDER).label());
    assertTrue(callio.orders().list(new ListOrdersParams().user(CUST)).stream().anyMatch(x -> x.id().equals(ORDER)));
    assertEquals(AGENT, callio.orders().assign(ORDER, AGENT).agent());
    assertEquals("closed", callio.orders().close(ORDER).status());
    assertEquals("active", callio.orders().reopen(ORDER).status());
    assertEquals("closed", callio.orders().update(ORDER, new UpdateOrderParams().status("closed")).status());
    assertThrows(NotFoundException.class, () -> callio.orders().get(ORDER + "-nope"));

    List<String> seen = new ArrayList<>();
    for (CallioEvent e : callio.events().iterate(new ListEventsParams().after(Math.max(0, before - 1)).types("order.").limit(100))) {
      if (ORDER.equals(e.orderId())) seen.add(e.type());
    }
    for (String t : Arrays.asList("order.created", "order.assigned", "order.closed", "order.reopened")) assertTrue(seen.contains(t), t + " in " + seen);
  }

  @Test @Order(4) void groups() {
    Group g = callio.groups().create(new CreateGroupParams(GROUP, "SDK IT group", List.of(CUST, AGENT)));
    groupMade = true;
    assertEquals(2, g.members().size());
    assertEquals("SDK IT group", callio.groups().get(GROUP).name());
    Group u = callio.groups().update(GROUP, new UpdateGroupParams().name("SDK IT renamed").remove(AGENT));
    assertEquals("SDK IT renamed", u.name());
    assertEquals(List.of(CUST), Arrays.asList(u.members().stream().map(GroupMember::username).toArray()));
    assertTrue(callio.groups().list().stream().anyMatch(x -> x.id().equals(GROUP)));
    assertEquals(Boolean.TRUE, callio.groups().delete(GROUP).get("ok"));
    groupMade = false;
    assertThrows(NotFoundException.class, () -> callio.groups().get(GROUP));
  }

  @Test @Order(5) void recordingsAndCdr() {
    List<Recording> recs = callio.recordings().list(new ListRecordingsParams().limit(5));
    assertNotNull(recs);
    if (!recs.isEmpty()) {
      assertEquals(recs.get(0).id(), callio.recordings().get(recs.get(0).id()).id());
      if ("1".equals(System.getenv("CALLIO_IT_AUDIO"))) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        assertEquals(recs.get(0).bytes(), callio.recordings().download(recs.get(0).id(), out, "SDK integration test"));
        assertEquals("OggS", new String(Arrays.copyOf(out.toByteArray(), 4), StandardCharsets.US_ASCII));
      }
    }
    assertThrows(NotFoundException.class, () -> callio.recordings().get("no-such-recording"));
    assertThrows(NotFoundException.class, () -> callio.recordings().audio("no-such-recording", "SDK integration test"));
    CdrPage cdr = callio.cdr().list(new ListCdrParams().days(30));
    assertEquals(30, cdr.days());
    assertNotNull(cdr.calls());
  }

  @Test @Order(6) void erasure() {
    ErasureResult r = callio.users().delete(AGENT, "SDK integration test cleanup");
    assertTrue(r.ok());
    assertTrue(r.alias().startsWith("erased-"), r.alias());
    users.remove(AGENT);
    assertThrows(NotFoundException.class, () -> callio.users().get(AGENT));
  }
}
