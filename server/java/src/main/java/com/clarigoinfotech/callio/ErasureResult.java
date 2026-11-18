package com.clarigoinfotech.callio;

import java.util.List;

import java.util.Map;

/** The result of a PDPL erasure ({@code users.delete}). */
public class ErasureResult extends ApiObject {
  public ErasureResult(Map<String, Object> data) { super(data); }

  public boolean ok() { return bool("ok"); }
  /** The pseudonym that replaced the user in records that are kept (events, orders, others' messages). */
  public String alias() { return str("alias"); }
  public Map<String, Object> removed() { return map("removed"); }
  public List<String> recordingsKeptOnLegalHold() { return strings("recordingsKeptOnLegalHold"); }
}
