package com.clarigoinfotech.callio;

import java.util.List;

import java.util.Map;

/** One page of the event feed. Pass {@link #next()} as {@code after} for the following page. */
public class EventPage extends ApiObject {
  public EventPage(Map<String, Object> data) { super(data); }

  public List<CallioEvent> events() { return list("events", CallioEvent::new); }
  public long next() { return lng("next"); }
}
