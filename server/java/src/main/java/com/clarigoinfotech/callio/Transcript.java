package com.clarigoinfotech.callio;

import java.util.List;

import java.util.Map;

/** A recording's transcript. */
public class Transcript extends ApiObject {
  public Transcript(Map<String, Object> data) { super(data); }

  public String text() { return str("text"); }
  public String language() { return str("language"); }
  /** Timed segments: each has {@code start}, {@code end} (seconds) and {@code text}. */
  public List<Map<String, Object>> segments() { return list("segments", m -> m); }
}
