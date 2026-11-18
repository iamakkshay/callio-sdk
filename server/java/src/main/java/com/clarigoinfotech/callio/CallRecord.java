package com.clarigoinfotech.callio;

import java.util.Map;

/** One row of the call records. */
public class CallRecord extends ApiObject {
  public CallRecord(Map<String, Object> data) { super(data); }

  public String callId() { return str("callId"); }
  public String tenant() { return str("tenant"); }
  public String from() { return str("from"); }
  public String to() { return str("to"); }
  public String fromType() { return str("fromType"); }
  public String toType() { return str("toType"); }
  public String direction() { return str("direction"); }
  public boolean support() { return bool("support"); }
  public String orderId() { return str("orderId"); }
  public String entryPoint() { return str("entryPoint"); }
  public String outcome() { return str("outcome"); }
  public String endReason() { return str("endReason"); }
  public double durationSec() { return dbl("durationSec"); }
  public Double answerSec() { return dblOrNull("answerSec"); }
  public String startedAt() { return str("startedAt"); }
  public String answeredAt() { return str("answeredAt"); }
  public String endedAt() { return str("endedAt"); }
  public Object quality() { return get("quality"); }
  public Object client() { return get("client"); }
}
