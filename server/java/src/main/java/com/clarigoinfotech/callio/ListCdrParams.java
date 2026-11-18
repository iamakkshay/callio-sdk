package com.clarigoinfotech.callio;

/** Filters for {@code cdr.list}. */
public final class ListCdrParams extends Params<ListCdrParams> {
  /** 1–90 (default 7). */
  public ListCdrParams days(int v) { return set("days", v); }
  /** customer, agent or guest. */
  public ListCdrParams type(String v) { return set("type", v); }
}
