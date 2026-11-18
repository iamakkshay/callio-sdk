package com.clarigoinfotech.callio;

/** No response within the configured timeout. */
public class RequestTimeoutException extends ConnectionException {
  private static final long serialVersionUID = 1L;

  public RequestTimeoutException(String message, int status, Object body, String request) { super(message, status, body, request); }
}
