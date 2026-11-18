package com.clarigoinfotech.callio;

/** The body of {@code users.create}. */
public final class CreateUserParams extends Params<CreateUserParams> {
  public CreateUserParams(String username) { set("username", username); }

  public CreateUserParams displayName(String v) { return set("displayName", v); }
  /** customer or agent. */
  public CreateUserParams userType(String v) { return set("userType", v); }
  public CreateUserParams loginPassword(String v) { return set("loginPassword", v); }
  public CreateUserParams phone(String v) { return set("phone", v); }
}
