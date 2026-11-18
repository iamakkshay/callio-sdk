package com.clarigoinfotech.callio;

/** 410: the recording was deleted. */
public class GoneException extends CallioException {
  private static final long serialVersionUID = 1L;

  public GoneException(String message, int status, Object body, String request) { super(message, status, body, request); }
}
