package com.clarigoinfotech.callio;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Filters for {@code events.list} / {@code events.iterate}. */
public final class ListEventsParams extends Params<ListEventsParams> {
  public ListEventsParams after(long v) { return set("after", v); }
  public ListEventsParams limit(int v) { return set("limit", v); }
  /** Type prefixes, e.g. {@code types("call.", "chat.")}. */
  public ListEventsParams types(String... v) { return set("types", Arrays.asList(v)); }
  public ListEventsParams types(List<String> v) { return set("types", new ArrayList<>(v)); }
}
