package com.clarigoinfotech.callio;

import java.time.Duration;
import java.util.Optional;

/** 429: the organisation's request rate is exceeded. {@link #retryAfter()} is from the Retry-After header. */
public class RateLimitException extends CallioException {
  private static final long serialVersionUID = 1L;
  private final Duration retryAfter;

  public RateLimitException(String message, int status, Object body, String request, Duration retryAfter) {
    super(message, status, body, request);
    this.retryAfter = retryAfter;
  }

  public Optional<Duration> retryAfter() { return Optional.ofNullable(retryAfter); }
}
