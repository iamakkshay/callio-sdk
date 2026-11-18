package com.clarigoinfotech.callio;

/** The body of {@code orders.update}: {@code agent("drv-7")} reassigns, {@code agent(null)} unassigns, {@code status("closed")} closes. */
public final class UpdateOrderParams extends Params<UpdateOrderParams> {
  public UpdateOrderParams agent(String v) { return set("agent", v); }
  /** active or closed. */
  public UpdateOrderParams status(String v) { return set("status", v); }
  public UpdateOrderParams label(String v) { return set("label", v); }
}
