package com.clarigoinfotech.callio;

import java.util.Map;

/** One entry of the event feed. */
public class CallioEvent extends ApiObject {
  public CallioEvent(Map<String, Object> data) { super(data); }

  public long id() { return lng("id"); }
  public String type() { return str("type"); }
  public String callId() { return str("callId"); }
  public String from() { return str("from"); }
  public String to() { return str("to"); }
  public String fromType() { return str("fromType"); }
  public String toType() { return str("toType"); }
  public String orderId() { return str("orderId"); }
  public String at() { return str("at"); }
  public Map<String, Object> payload() { return map("payload"); }
}
