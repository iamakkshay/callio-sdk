package com.clarigoinfotech.callio;

import java.util.Map;

/** A call recording's metadata. */
public class Recording extends ApiObject {
  public Recording(Map<String, Object> data) { super(data); }

  public String id() { return str("id"); }
  public String tenant() { return str("tenant"); }
  public String callRef() { return str("callRef"); }
  public String caller() { return str("caller"); }
  public String callee() { return str("callee"); }
  public String callType() { return str("callType"); }
  public String orderId() { return str("orderId"); }
  public String startedAt() { return str("startedAt"); }
  public double durationSec() { return dbl("durationSec"); }
  public long bytes() { return lng("bytes"); }
  public String format() { return str("format"); }
  /** stored or deleted. */
  public String status() { return str("status"); }
  public boolean legalHold() { return bool("legalHold"); }
  public String holdReason() { return str("holdReason"); }
  public String retainUntil() { return str("retainUntil"); }
  public String deletedAt() { return str("deletedAt"); }
  public String deleteReason() { return str("deleteReason"); }
  public String createdAt() { return str("createdAt"); }
  /** The transcript state ({@code status}, {@code language}, {@code error}), or an empty map when there is none. */
  public Map<String, Object> transcript() { return map("transcript"); }
}
