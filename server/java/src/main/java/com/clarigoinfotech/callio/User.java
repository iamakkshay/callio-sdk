package com.clarigoinfotech.callio;

import java.util.Map;

/** A Callio user. */
public class User extends ApiObject {
  public User(Map<String, Object> data) { super(data); }

  public String username() { return str("username"); }
  public String displayName() { return str("displayName"); }
  /** customer, agent or guest. */
  public String userType() { return str("userType"); }
  /** The user's SIP extension. */
  public String extension() { return str("extension"); }
  public String segment() { return str("segment"); }
  public boolean disabled() { return bool("disabled"); }
  /** Masked phone fallback number (only on get/create/update, not in list results). */
  public String phone() { return str("phone"); }
}
