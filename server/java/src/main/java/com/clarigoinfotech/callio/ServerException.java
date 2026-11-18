package com.clarigoinfotech.callio;

/** 5xx from the platform. */
public class ServerException extends CallioException {
  private static final long serialVersionUID = 1L;

  public ServerException(String message, int status, Object body, String request) { super(message, status, body, request); }
}
