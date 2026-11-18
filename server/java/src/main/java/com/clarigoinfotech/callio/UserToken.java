package com.clarigoinfotech.callio;

import java.util.LinkedHashMap;
import java.util.Map;

/** The result of {@code tokens.forUser}. */
public class UserToken extends Token {
  public UserToken(Map<String, Object> data) { super(data); }

  static UserToken of(Token t, boolean created) {
    Map<String, Object> m = new LinkedHashMap<>(t.raw());
    m.put("created", created);
    return new UserToken(m);
  }

  /** True when forUser created the user on this call. */
  public boolean created() { return bool("created"); }
}
