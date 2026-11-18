package com.clarigoinfotech.callio;

/** Filters for {@code orders.list}. */
public final class ListOrdersParams extends Params<ListOrdersParams> {
  /** active or closed. */
  public ListOrdersParams status(String v) { return set("status", v); }
  public ListOrdersParams user(String v) { return set("user", v); }
  public ListOrdersParams limit(int v) { return set("limit", v); }
}
