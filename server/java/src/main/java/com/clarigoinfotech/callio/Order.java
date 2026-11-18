package com.clarigoinfotech.callio;

import java.util.Map;

/** An order: a customer and (optionally) the agent assigned right now. */
public class Order extends ApiObject {
  public Order(Map<String, Object> data) { super(data); }

  public String id() { return str("id"); }
  public String customer() { return str("customer"); }
  /** Null when unassigned. */
  public String agent() { return str("agent"); }
  /** active or closed. */
  public String status() { return str("status"); }
  public String label() { return str("label"); }
  public String createdAt() { return str("createdAt"); }
  public String updatedAt() { return str("updatedAt"); }
  public String closedAt() { return str("closedAt"); }
}
