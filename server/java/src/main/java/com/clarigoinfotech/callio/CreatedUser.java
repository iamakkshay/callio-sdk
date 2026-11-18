package com.clarigoinfotech.callio;

import java.util.Map;

/** The result of {@code users.create}. */
public class CreatedUser extends User {
  public CreatedUser(Map<String, Object> data) { super(data); }

  /** Returned once, when the user was created without a loginPassword; otherwise null. */
  public String initialPassword() { return str("initialPassword"); }
}
