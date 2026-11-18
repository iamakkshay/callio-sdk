package com.clarigoinfotech.callio;

/** Filters for {@code users.list}. */
public final class ListUsersParams extends Params<ListUsersParams> {
  public ListUsersParams q(String v) { return set("q", v); }
  /** customer or agent. */
  public ListUsersParams type(String v) { return set("type", v); }
  /** active or disabled. */
  public ListUsersParams status(String v) { return set("status", v); }
  public ListUsersParams segment(String v) { return set("segment", v); }
  public ListUsersParams limit(int v) { return set("limit", v); }
}
