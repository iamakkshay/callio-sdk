package com.clarigoinfotech.callio;

/** Argument checks shared by the resources. */
final class Seg {
  private Seg() {}

  /** A path segment: required, never "." or "..", percent-encoded. */
  static String of(String s) {
    if (s == null || s.isEmpty() || s.equals(".") || s.equals("..")) {
      throw new IllegalArgumentException("Callio: an id / username is required (and cannot be \".\" or \"..\")");
    }
    return CallioHttp.encodeSegment(s);
  }

  static String reason(String r) {
    String t = r == null ? "" : r.trim();
    if (t.codePointCount(0, t.length()) < 5) {
      throw new IllegalArgumentException("Callio: a reason of at least 5 characters is required to fetch a recording");
    }
    return t;
  }
}
