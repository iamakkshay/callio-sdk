package com.clarigoinfotech.callio;

/** The body of {@code users.update}. Only fields you set are sent; {@code segment(null)} / {@code phone(null)} clear them. */
public final class UpdateUserParams extends Params<UpdateUserParams> {
  public UpdateUserParams displayName(String v) { return set("displayName", v); }
  public UpdateUserParams userType(String v) { return set("userType", v); }
  public UpdateUserParams disabled(boolean v) { return set("disabled", v); }
  public UpdateUserParams segment(String v) { return set("segment", v); }
  public UpdateUserParams phone(String v) { return set("phone", v); }
}
