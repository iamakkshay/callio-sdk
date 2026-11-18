package com.clarigoinfotech.callio;

/** 401: the API key is missing, wrong or revoked. */
public class AuthenticationException extends CallioException {
  private static final long serialVersionUID = 1L;

  public AuthenticationException(String message, int status, Object body, String request) { super(message, status, body, request); }
}
