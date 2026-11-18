package com.clarigoinfotech.callio;

import java.time.Duration;
import java.util.Locale;

/**
 * The Callio tenant API client. Keep it on your server: the API key gives full access to your organisation's
 * users, orders and recordings. Thread-safe; create one and share it.
 *
 * <pre>{@code
 * Callio callio = Callio.builder().apiKey(System.getenv("CALLIO_API_KEY")).baseUrl("https://api.example.sa").build();
 * UserToken t = callio.tokens().forUser("cust-42", new ForUserOptions().displayName("Sara").userType("customer"));
 * }</pre>
 */
public final class Callio {
  private final CallioHttp http;
  private final Users users;
  private final Tokens tokens;
  private final Orders orders;
  private final Recordings recordings;
  private final Groups groups;
  private final Events events;
  private final Cdr cdr;

  private Callio(CallioHttp http) {
    this.http = http;
    this.users = new Users(http);
    this.tokens = new Tokens(http, users);
    this.orders = new Orders(http);
    this.recordings = new Recordings(http);
    this.groups = new Groups(http);
    this.events = new Events(http);
    this.cdr = new Cdr(http);
  }

  /** A client configured from CALLIO_API_KEY and CALLIO_BASE_URL. */
  public static Callio fromEnv() { return builder().build(); }

  public static Builder builder() { return new Builder(); }

  public Users users() { return users; }
  public Tokens tokens() { return tokens; }
  public Orders orders() { return orders; }
  public Recordings recordings() { return recordings; }
  public Groups groups() { return groups; }
  public Events events() { return events; }
  public Cdr cdr() { return cdr; }

  /** The underlying HTTP client ({@code request()} for endpoints the SDK doesn't wrap yet). */
  public CallioHttp http() { return http; }

  /** Never prints the key. */
  @Override public String toString() { return "Callio{baseUrl=" + http.baseUrl() + "}"; }

  /** Options for {@link Callio}. */
  public static final class Builder {
    private String apiKey;
    private String baseUrl;
    private Duration timeout = Duration.ofSeconds(30);
    private int maxRetries = 2;
    private String userAgent;
    private boolean allowInsecure;
    private Transport transport;

    private Builder() {}

    /** The tenant API key, {@code cio_<id>_<secret>}. Defaults to the CALLIO_API_KEY environment variable. */
    public Builder apiKey(String v) { this.apiKey = v; return this; }

    /** Your Callio host, e.g. {@code https://api.example.sa}. Defaults to CALLIO_BASE_URL. */
    public Builder baseUrl(String v) { this.baseUrl = v; return this; }

    /** Per-attempt timeout (default 30 s). */
    public Builder timeout(Duration v) { this.timeout = v; return this; }

    /** Retries for idempotent requests on 429 / 5xx / network errors (default 2). */
    public Builder maxRetries(int v) { this.maxRetries = Math.max(0, v); return this; }

    /** Appended to the User-Agent, e.g. {@code my-backend/1.4}. */
    public Builder userAgent(String v) { this.userAgent = v; return this; }

    /** Permit an {@code http://} base URL. Only for a local development stack: the key travels in clear text. */
    public Builder allowInsecure(boolean v) { this.allowInsecure = v; return this; }

    /** Replace the HTTP transport (tests, proxies, instrumentation). Default: {@link JdkTransport}. */
    public Builder transport(Transport v) { this.transport = v; return this; }

    public Callio build() {
      String key = apiKey != null && !apiKey.isEmpty() ? apiKey : System.getenv("CALLIO_API_KEY");
      String url = baseUrl != null && !baseUrl.isEmpty() ? baseUrl : System.getenv("CALLIO_BASE_URL");
      if (key == null || key.isEmpty()) throw new CallioException("Callio: apiKey is required (or set CALLIO_API_KEY)");
      if (url == null || url.isEmpty()) throw new CallioException("Callio: baseUrl is required (or set CALLIO_BASE_URL), e.g. https://api.example.sa");
      String lower = url.toLowerCase(Locale.ROOT);
      boolean https = lower.startsWith("https://") && lower.length() > 8;
      boolean http = lower.startsWith("http://") && lower.length() > 7;
      if (!https && !(allowInsecure && http)) {
        throw new CallioException("Callio: baseUrl must start with https:// (http:// only with allowInsecure(true), for a local stack)");
      }
      if (timeout == null || timeout.isNegative() || timeout.isZero()) throw new CallioException("Callio: timeout must be positive");
      String ua = "callio-server-java/" + Version.VERSION + " java/" + System.getProperty("java.version", "?")
          + (userAgent != null && !userAgent.isEmpty() ? " " + userAgent : "");
      String trimmed = url.replaceAll("/+$", "");
      return new Callio(new CallioHttp(key, trimmed, timeout, maxRetries, ua, transport != null ? transport : new JdkTransport()));
    }

    /** Never prints the key. */
    @Override public String toString() { return "Callio.Builder{baseUrl=" + baseUrl + "}"; }
  }
}
