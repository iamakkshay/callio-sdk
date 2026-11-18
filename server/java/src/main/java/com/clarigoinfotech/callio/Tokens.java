package com.clarigoinfotech.callio;

import java.util.LinkedHashMap;
import java.util.Map;

/** App tokens. */
public final class Tokens {
  private final CallioHttp http;
  private final Users users;

  Tokens(CallioHttp http, Users users) { this.http = http; this.users = users; }

  /** A short-lived app token for an existing user; {@code ttlSec} 60–3600 (null for the default 900). */
  public Token create(String username, Integer ttlSec) { return create(username, ttlSec, null); }

  /** As {@link #create(String, Integer)}, for one device: {@code deviceId} is the app's device id (its X-Device-Id);
   *  null ties the token to the first device that uses it. */
  public Token create(String username, Integer ttlSec, String deviceId) {
    Map<String, Object> body = new LinkedHashMap<>();
    body.put("username", username);
    if (ttlSec != null) body.put("ttlSec", ttlSec);
    if (deviceId != null) body.put("deviceId", deviceId);
    return new Token(http.requestObject("POST", "/api/v1/tokens", null, body));
  }

  public Token create(String username) { return create(username, null); }

  /**
   * The common job: make sure the app user exists, then issue their token. Creates the user if missing (a 409
   * means they already exist, which is fine). An existing user's display name and type are left as they are;
   * check {@code userType()} on the result if it matters.
   */
  public UserToken forUser(String username, ForUserOptions options) {
    Map<String, Object> o = options == null ? new LinkedHashMap<String, Object>() : options.toMap();
    CreateUserParams p = new CreateUserParams(username);
    for (String k : new String[] {"displayName", "userType", "phone"}) if (o.get(k) != null) p.set(k, o.get(k));
    boolean created = false;
    try {
      users.create(p);
      created = true;
    } catch (ConflictException e) {
      // already exists
    }
    Object ttl = o.get("ttlSec");
    Object dev = o.get("deviceId");
    Token t = create(username, ttl instanceof Number ? ((Number) ttl).intValue() : null, dev == null ? null : dev.toString());
    return UserToken.of(t, created);
  }

  public UserToken forUser(String username) { return forUser(username, null); }
}
