package com.clarigoinfotech.callio;

import java.util.Collections;
import java.util.List;
import java.util.Map;

/** Orders: which customer and which agent belong together right now. */
public final class Orders {
  private final CallioHttp http;

  Orders(CallioHttp http) { this.http = http; }

  private Order one(String method, String path, Object body) {
    return new Order(Json.asMap(http.requestObject(method, path, null, body).get("order")));
  }

  /** ConflictException if the id exists, ValidationException for an unknown customer/agent or a wrong user type. */
  public Order create(CreateOrderParams params) { return one("POST", "/api/v1/orders", params); }

  public List<Order> list(ListOrdersParams params) {
    Map<String, Object> q = params == null ? Collections.<String, Object>emptyMap() : params.toMap();
    return new Users.Wrap(http.requestObject("GET", "/api/v1/orders", q, null)).list("orders", Order::new);
  }

  public List<Order> list() { return list(null); }

  public Order get(String id) { return one("GET", "/api/v1/orders/" + Seg.of(id), null); }

  /** Reassign ({@code agent}), unassign ({@code agent(null)}), close or reopen ({@code status}), relabel. */
  public Order update(String id, UpdateOrderParams params) { return one("PATCH", "/api/v1/orders/" + Seg.of(id), params); }

  /** Assign an agent; {@code null} unassigns. */
  public Order assign(String id, String agent) { return update(id, new UpdateOrderParams().agent(agent)); }

  public Order close(String id) { return update(id, new UpdateOrderParams().status("closed")); }

  public Order reopen(String id) { return update(id, new UpdateOrderParams().status("active")); }
}
