package com.clarigoinfotech.callio;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Base of request parameters: a JSON object built with fluent setters. Only fields you set are sent, and a
 * field set to {@code null} is sent as JSON null (e.g. {@code new UpdateOrderParams().agent(null)} unassigns).
 */
public abstract class Params<P extends Params<P>> {
  private final Map<String, Object> fields = new LinkedHashMap<>();

  @SuppressWarnings("unchecked")
  protected P self() { return (P) this; }

  /** Sets any field, including ones this SDK version doesn't know yet. */
  public P set(String field, Object value) { fields.put(field, value); return self(); }

  /** The fields that will be sent. */
  public Map<String, Object> toMap() { return Collections.unmodifiableMap(fields); }

  @Override public String toString() { return getClass().getSimpleName() + Json.stringify(fields); }
}
