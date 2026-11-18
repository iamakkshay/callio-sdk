package com.clarigoinfotech.callio;

/** 400: invalid input (bad id or username, unknown user, wrong user type, missing reason…). */
public class ValidationException extends CallioException {
  private static final long serialVersionUID = 1L;

  public ValidationException(String message, int status, Object body, String request) { super(message, status, body, request); }
}
