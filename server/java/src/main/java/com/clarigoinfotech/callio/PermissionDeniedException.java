package com.clarigoinfotech.callio;

/** 403: the key is valid but the request is not allowed: the organisation is suspended, a seat quota is
 * reached, the user is disabled, or the call came from a network outside the organisation's API allow-list. */
public class PermissionDeniedException extends CallioException {
  private static final long serialVersionUID = 1L;

  public PermissionDeniedException(String message, int status, Object body, String request) { super(message, status, body, request); }
}
