package com.clarigoinfotech.callio;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.Function;

/**
 * Base of every model the API returns. Typed getters cover the documented fields; {@link #raw()} holds the
 * whole JSON object, so fields the platform adds later are still reachable.
 */
public abstract class ApiObject {
  private final Map<String, Object> data;

  protected ApiObject(Map<String, Object> data) {
    this.data = data == null ? Collections.<String, Object>emptyMap() : Collections.unmodifiableMap(data);
  }

  /** The JSON object as parsed (unmodifiable). */
  public Map<String, Object> raw() { return data; }

  /** A field by name (null when absent). */
  public Object get(String field) { return data.get(field); }

  protected String str(String k) { Object v = data.get(k); return v == null ? null : String.valueOf(v); }

  protected boolean bool(String k) { return Boolean.TRUE.equals(data.get(k)); }

  protected long lng(String k) { Object v = data.get(k); return v instanceof Number ? ((Number) v).longValue() : 0L; }

  protected Long lngOrNull(String k) { Object v = data.get(k); return v instanceof Number ? ((Number) v).longValue() : null; }

  protected double dbl(String k) { Object v = data.get(k); return v instanceof Number ? ((Number) v).doubleValue() : 0d; }

  protected Double dblOrNull(String k) { Object v = data.get(k); return v instanceof Number ? ((Number) v).doubleValue() : null; }

  protected Map<String, Object> map(String k) { return Json.asMap(data.get(k)); }

  protected <T> List<T> list(String k, Function<Map<String, Object>, T> f) {
    List<T> out = new ArrayList<>();
    for (Object o : Json.asList(data.get(k))) out.add(f.apply(Json.asMap(o)));
    return Collections.unmodifiableList(out);
  }

  protected List<String> strings(String k) {
    List<String> out = new ArrayList<>();
    for (Object o : Json.asList(data.get(k))) out.add(String.valueOf(o));
    return Collections.unmodifiableList(out);
  }

  @Override public String toString() { return getClass().getSimpleName() + Json.stringify(data); }

  @Override public boolean equals(Object o) {
    return o != null && o.getClass() == getClass() && Objects.equals(((ApiObject) o).data, data);
  }

  @Override public int hashCode() { return data.hashCode(); }
}
