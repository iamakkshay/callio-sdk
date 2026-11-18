package com.clarigoinfotech.callio;

/** Filters for {@code recordings.list}. Dates may be ISO strings, {@code Instant}s or {@code LocalDate}s. */
public final class ListRecordingsParams extends Params<ListRecordingsParams> {
  /** ISO date, Instant, OffsetDateTime or LocalDate. */
  public ListRecordingsParams from(Object v) { return set("from", v); }
  /** ISO date, Instant, OffsetDateTime or LocalDate. */
  public ListRecordingsParams to(Object v) { return set("to", v); }
  /** Extension of either party. */
  public ListRecordingsParams user(String v) { return set("user", v); }
  public ListRecordingsParams callId(String v) { return set("callId", v); }
  public ListRecordingsParams orderId(String v) { return set("orderId", v); }
  /** Seconds. */
  public ListRecordingsParams minDuration(int v) { return set("minDuration", v); }
  /** Seconds. */
  public ListRecordingsParams maxDuration(int v) { return set("maxDuration", v); }
  /** stored (default), deleted or all. */
  public ListRecordingsParams status(String v) { return set("status", v); }
  public ListRecordingsParams limit(int v) { return set("limit", v); }
}
