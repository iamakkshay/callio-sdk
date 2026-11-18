package com.clarigoinfotech.callio;

import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.Spliterator;
import java.util.Spliterators;
import java.util.stream.Stream;
import java.util.stream.StreamSupport;

/** The event feed (BI). */
public final class Events {
  private final CallioHttp http;

  Events(CallioHttp http) { this.http = http; }

  /** One page of the event feed, in order. Pass the returned {@code next()} as {@code after} for the following page. */
  public EventPage list(ListEventsParams params) {
    Map<String, Object> q = new LinkedHashMap<>();
    if (params != null) {
      Map<String, Object> p = params.toMap();
      for (String k : new String[] {"after", "limit", "types"}) if (p.containsKey(k)) q.put(k, p.get(k));
    }
    return new EventPage(http.requestObject("GET", "/api/v1/events", q, null));
  }

  public EventPage list() { return list(null); }

  /**
   * Every event after {@code after}, page by page, until the feed is caught up. Lazy: pages are fetched as you
   * iterate. Remember the last {@code id()} to resume.
   */
  public Iterable<CallioEvent> iterate(ListEventsParams params) {
    Map<String, Object> base = params == null ? new LinkedHashMap<String, Object>() : params.toMap();
    Object a = base.get("after");
    long start = a instanceof Number ? ((Number) a).longValue() : 0L;
    return () -> new Iterator<CallioEvent>() {
      long after = start;
      Iterator<CallioEvent> page;
      boolean done;

      @Override public boolean hasNext() {
        while (page == null || !page.hasNext()) {
          if (done) return false;
          ListEventsParams p = new ListEventsParams();
          for (Map.Entry<String, Object> e : base.entrySet()) p.set(e.getKey(), e.getValue());
          p.after(after);
          EventPage pg = list(p);
          List<CallioEvent> evs = pg.events();
          page = evs.iterator();
          if (evs.isEmpty() || pg.next() <= after) done = true;
          else after = pg.next();
        }
        return true;
      }

      @Override public CallioEvent next() {
        if (!hasNext()) throw new NoSuchElementException();
        return page.next();
      }
    };
  }

  public Iterable<CallioEvent> iterate() { return iterate(null); }

  /** {@link #iterate} as a sequential stream. */
  public Stream<CallioEvent> stream(ListEventsParams params) {
    return StreamSupport.stream(Spliterators.spliteratorUnknownSize(iterate(params).iterator(), Spliterator.ORDERED | Spliterator.NONNULL), false);
  }
}
