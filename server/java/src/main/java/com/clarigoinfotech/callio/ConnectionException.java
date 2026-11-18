package com.clarigoinfotech.callio;

/** No response: DNS, TLS, connection reset… */
public class ConnectionException extends CallioException {
  private static final long serialVersionUID = 1L;

  public ConnectionException(String message, int status, Object body, String request) { super(message, status, body, request); }
}
