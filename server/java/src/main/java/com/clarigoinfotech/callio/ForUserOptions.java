package com.clarigoinfotech.callio;

/** Options for {@code tokens.forUser}. */
public final class ForUserOptions extends Params<ForUserOptions> {
  public ForUserOptions displayName(String v) { return set("displayName", v); }
  /** customer or agent. */
  public ForUserOptions userType(String v) { return set("userType", v); }
  /** 60–3600 s (default 900). */
  public ForUserOptions ttlSec(int v) { return set("ttlSec", v); }
  /** The app's device id (its X-Device-Id): the token works on that device only. */
  public ForUserOptions deviceId(String v) { return set("deviceId", v); }
  public ForUserOptions phone(String v) { return set("phone", v); }
}
