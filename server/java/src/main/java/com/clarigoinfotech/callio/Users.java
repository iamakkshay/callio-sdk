package com.clarigoinfotech.callio;

import java.util.Collections;
import java.util.List;
import java.util.Map;

/** App users. */
public final class Users {
  private final CallioHttp http;

  Users(CallioHttp http) { this.http = http; }

  /** Search users. */
  public List<User> list(ListUsersParams params) {
    Map<String, Object> q = params == null ? Collections.<String, Object>emptyMap() : params.toMap();
    return new Wrap(http.requestObject("GET", "/api/v1/users", q, null)).list("users", User::new);
  }

  public List<User> list() { return list(null); }

  /** Create a user. ConflictException (409) if the username exists, PermissionDeniedException (403) at the seat quota. */
  public CreatedUser create(CreateUserParams params) {
    return new CreatedUser(Json.asMap(http.requestObject("POST", "/api/v1/users", null, params).get("user")));
  }

  public CreatedUser create(String username) { return create(new CreateUserParams(username)); }

  public User get(String username) {
    return new User(Json.asMap(http.requestObject("GET", "/api/v1/users/" + Seg.of(username), null, null).get("user")));
  }

  /** Changing the type or disabling ends the user's sessions. */
  public User update(String username, UpdateUserParams params) {
    return new User(Json.asMap(http.requestObject("PATCH", "/api/v1/users/" + Seg.of(username), null, params).get("user")));
  }

  public User disable(String username) { return update(username, new UpdateUserParams().disabled(true)); }

  public User enable(String username) { return update(username, new UpdateUserParams().disabled(false)); }

  /** End every session the user has open. Returns {@code {"ok": true}}. */
  public Map<String, Object> signOut(String username) {
    return http.requestObject("POST", "/api/v1/users/" + Seg.of(username) + "/sign-out", null, null);
  }

  /** PDPL access request: everything held about the user (the platform's shape; it may grow). */
  public Map<String, Object> export(String username) {
    return http.requestObject("GET", "/api/v1/users/" + Seg.of(username) + "/export", null, null);
  }

  /** PDPL erasure: deletes the account and its data (recordings on legal hold are kept). Irreversible. */
  public ErasureResult delete(String username, String reason) {
    return new ErasureResult(http.requestObject("DELETE", "/api/v1/users/" + Seg.of(username), null, Collections.singletonMap("reason", reason)));
  }

  /** Lets resources reuse ApiObject's list helper on a response envelope. */
  static final class Wrap extends ApiObject {
    Wrap(Map<String, Object> m) { super(m); }
  }
}
