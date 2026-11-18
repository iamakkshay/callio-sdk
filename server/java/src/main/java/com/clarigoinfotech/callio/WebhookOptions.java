package com.clarigoinfotech.callio;

import java.time.Clock;
import java.time.Duration;

/** Options for {@link Webhooks#verifyRequest} and {@link Webhooks#parseRequest}. */
public final class WebhookOptions {
  Duration tolerance = Webhooks.DEFAULT_TOLERANCE;
  boolean allowLegacy;
  Clock clock = Clock.systemUTC();

  /** How far X-Callio-Timestamp may be from now (default 300 s). */
  public WebhookOptions tolerance(Duration v) {
    if (v == null || v.isNegative() || v.isZero()) throw new IllegalArgumentException("Callio: the tolerance must be positive");
    this.tolerance = v;
    return this;
  }

  /**
   * Accept a request without X-Callio-Timestamp by checking the legacy X-NGX-Signature (body only, so such a
   * request could be a replay). Off by default.
   */
  public WebhookOptions allowLegacy(boolean v) { this.allowLegacy = v; return this; }

  /** Replace the clock (tests). */
  public WebhookOptions clock(Clock v) { this.clock = v; return this; }
}
