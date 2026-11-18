package com.clarigoinfotech.callio;

import java.util.List;

import java.util.Map;

/** Call records for a window of days. */
public class CdrPage extends ApiObject {
  public CdrPage(Map<String, Object> data) { super(data); }

  public long days() { return lng("days"); }
  public List<CallRecord> calls() { return list("calls", CallRecord::new); }
}
