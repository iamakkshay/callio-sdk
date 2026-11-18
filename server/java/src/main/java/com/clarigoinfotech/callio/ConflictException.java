package com.clarigoinfotech.callio;

/** 409: it already exists (user, order). */
public class ConflictException extends CallioException {
  private static final long serialVersionUID = 1L;

  public ConflictException(String message, int status, Object body, String request) { super(message, status, body, request); }
}
