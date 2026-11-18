package com.clarigoinfotech.callio;

/** A bad or missing webhook signature or timestamp (status 401), or a body that is not a Callio event (400). */
public class WebhookVerificationException extends CallioException {
  private static final long serialVersionUID = 1L;

  public WebhookVerificationException(String message, int status, Object body, String request) { super(message, status, body, request); }

  public WebhookVerificationException(String message, int status) { super(message, status, null, null); }
}
