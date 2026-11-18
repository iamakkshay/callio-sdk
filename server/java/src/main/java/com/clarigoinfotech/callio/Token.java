package com.clarigoinfotech.callio;

import java.util.Map;

/** A short-lived app token. */
public class Token extends ApiObject {
  public Token(Map<String, Object> data) { super(data); }

  /** A JWT for the app SDKs. */
  public String token() { return str("token"); }
  public String userType() { return str("userType"); }
  /** ISO 8601. */
  public String expiresAt() { return str("expiresAt"); }
}
