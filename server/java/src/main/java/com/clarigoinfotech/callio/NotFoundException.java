package com.clarigoinfotech.callio;

/** 404: no such user, order, group or recording (or no transcript yet). */
public class NotFoundException extends CallioException {
  private static final long serialVersionUID = 1L;

  public NotFoundException(String message, int status, Object body, String request) { super(message, status, body, request); }
}
