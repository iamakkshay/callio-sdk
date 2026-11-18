package com.clarigoinfotech.callio;

import java.util.Map;

/**
 * A verified webhook event. {@link #type()} is always set; the other fields depend on it:
 * <ul>
 *   <li>order.created | order.assigned | order.closed | order.reopened: {@link #order()}, {@link #by()};</li>
 *   <li>call.* / chat.* / location.*: callId, from, to, payload;</li>
 *   <li>recording.ready: callId, recordingId, durationSec, retainUntil (never audio);</li>
 *   <li>cc.chat-escalated: interaction, user, entryPoint, transcriptUrl;</li>
 *   <li>report.snapshot: windowDays, kpis, series, generatedAt.</li>
 * </ul>
 * New types may be added; ignore ones you don't handle. Use {@link #get(String)} or {@link #raw()} for any field.
 */
public final class WebhookEvent extends ApiObject {
  public WebhookEvent(Map<String, Object> data) { super(data); }

  /** Unique per event: use it to drop duplicates (store the ids you have handled). */
  public String id() { return str("id"); }

  public String type() { return str("type"); }

  public String tenantId() { return str("tenantId"); }

  public String at() { return str("at"); }

  /** The order, for order.* events (null otherwise). */
  public Order order() { Object o = get("order"); return o instanceof Map ? new Order(Json.asMap(o)) : null; }

  /** {@code apikey:<id>} or {@code admin:<username>}, for order.* events. */
  public String by() { return str("by"); }

  public String callId() { return str("callId"); }

  public String recordingId() { return str("recordingId"); }

  public boolean isOrderEvent() { String t = type(); return t != null && t.startsWith("order."); }

  public boolean isRecordingReady() { return "recording.ready".equals(type()); }
}
