package com.clarigoinfotech.callio;

/** 3xx: the server answered with a redirect. The SDK never follows one (it would carry the API key to
 * another host); usually the base URL is wrong (http:// instead of https://, or a moved host). */
public class RedirectException extends CallioException {
  private static final long serialVersionUID = 1L;

  public RedirectException(String message, int status, Object body, String request) { super(message, status, body, request); }
}
