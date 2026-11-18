package com.clarigoinfotech.callio;

/** The body of {@code orders.create}. */
public final class CreateOrderParams extends Params<CreateOrderParams> {
  public CreateOrderParams(String id, String customer) { set("id", id); set("customer", customer); }

  public CreateOrderParams agent(String v) { return set("agent", v); }
  public CreateOrderParams label(String v) { return set("label", v); }
}
