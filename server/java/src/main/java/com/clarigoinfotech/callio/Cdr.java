package com.clarigoinfotech.callio;

import java.util.Collections;
import java.util.Map;

/** Call records. */
public final class Cdr {
  private final CallioHttp http;

  Cdr(CallioHttp http) { this.http = http; }

  /** Call records for the last {@code days} (1–90, default 7): one row per call. */
  public CdrPage list(ListCdrParams params) {
    Map<String, Object> q = params == null ? Collections.<String, Object>emptyMap() : params.toMap();
    return new CdrPage(http.requestObject("GET", "/api/v1/cdr", q, null));
  }

  public CdrPage list() { return list(null); }
}
