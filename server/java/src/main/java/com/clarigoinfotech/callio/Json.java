package com.clarigoinfotech.callio;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A small JSON codec, so the SDK has no runtime dependencies. Objects parse to {@code LinkedHashMap<String,
 * Object>}, arrays to {@code ArrayList<Object>}, numbers to {@code Long} (or {@code BigInteger}) when integral
 * and {@code Double} (or {@code BigDecimal}) otherwise, plus {@code String}, {@code Boolean} and {@code null}.
 */
public final class Json {
  private Json() {}

  static final DateTimeFormatter ISO_MILLIS = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC);

  /** Thrown for malformed JSON. */
  public static final class JsonException extends RuntimeException {
    private static final long serialVersionUID = 1L;
    JsonException(String message) { super(message); }
  }

  // ---------------------------------------------------------------- writing

  /** Serialises maps, iterables, arrays, strings, numbers, booleans, null, dates, enums and SDK models. */
  public static String stringify(Object value) {
    StringBuilder sb = new StringBuilder();
    write(sb, value);
    return sb.toString();
  }

  @SuppressWarnings("unchecked")
  private static void write(StringBuilder sb, Object v) {
    if (v == null) { sb.append("null"); return; }
    if (v instanceof ApiObject) v = ((ApiObject) v).raw();
    if (v instanceof Params) v = ((Params<?>) v).toMap();
    if (v instanceof String) { quote(sb, (String) v); return; }
    if (v instanceof Boolean) { sb.append(v.toString()); return; }
    if (v instanceof Double || v instanceof Float) {
      double d = ((Number) v).doubleValue();
      if (Double.isNaN(d) || Double.isInfinite(d)) { sb.append("null"); return; }
      if (d == Math.rint(d) && Math.abs(d) < 1e15) { sb.append((long) d); return; }
      sb.append(v.toString());
      return;
    }
    if (v instanceof BigDecimal) { sb.append(((BigDecimal) v).toPlainString()); return; }
    if (v instanceof Number) { sb.append(v.toString()); return; }
    if (v instanceof Enum) { quote(sb, v.toString()); return; }
    if (v instanceof Instant) { quote(sb, ISO_MILLIS.format((Instant) v)); return; }
    if (v instanceof Date) { quote(sb, ISO_MILLIS.format(((Date) v).toInstant())); return; }
    if (v instanceof OffsetDateTime) { quote(sb, ISO_MILLIS.format(((OffsetDateTime) v).toInstant())); return; }
    if (v instanceof ZonedDateTime) { quote(sb, ISO_MILLIS.format(((ZonedDateTime) v).toInstant())); return; }
    if (v instanceof LocalDate) { quote(sb, v.toString()); return; }
    if (v instanceof Map) {
      sb.append('{');
      boolean first = true;
      for (Map.Entry<Object, Object> e : ((Map<Object, Object>) v).entrySet()) {
        if (!first) sb.append(',');
        first = false;
        quote(sb, String.valueOf(e.getKey()));
        sb.append(':');
        write(sb, e.getValue());
      }
      sb.append('}');
      return;
    }
    if (v instanceof Iterable) {
      sb.append('[');
      Iterator<Object> it = ((Iterable<Object>) v).iterator();
      while (it.hasNext()) { write(sb, it.next()); if (it.hasNext()) sb.append(','); }
      sb.append(']');
      return;
    }
    if (v instanceof Object[]) {
      Object[] a = (Object[]) v;
      sb.append('[');
      for (int i = 0; i < a.length; i++) { if (i > 0) sb.append(','); write(sb, a[i]); }
      sb.append(']');
      return;
    }
    throw new IllegalArgumentException("Callio: cannot serialise a " + v.getClass().getName() + " to JSON");
  }

  private static void quote(StringBuilder sb, String s) {
    sb.append('"');
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      switch (c) {
        case '"': sb.append("\\\""); break;
        case '\\': sb.append("\\\\"); break;
        case '\n': sb.append("\\n"); break;
        case '\r': sb.append("\\r"); break;
        case '\t': sb.append("\\t"); break;
        case '\b': sb.append("\\b"); break;
        case '\f': sb.append("\\f"); break;
        default:
          if (c < 0x20 || c == 0x2028 || c == 0x2029) sb.append(String.format("\\u%04x", (int) c));
          else sb.append(c);
      }
    }
    sb.append('"');
  }

  // ---------------------------------------------------------------- reading

  /** Parses one JSON value; throws {@link JsonException} for malformed input or trailing data. */
  public static Object parse(String text) {
    Parser p = new Parser(text);
    p.ws();
    Object v = p.value(0);
    p.ws();
    if (p.i != text.length()) throw p.err("unexpected trailing data");
    return v;
  }

  private static final class Parser {
    final String s;
    int i;
    Parser(String s) { this.s = s; }

    JsonException err(String m) { return new JsonException("Callio: invalid JSON at " + i + ": " + m); }

    void ws() { while (i < s.length()) { char c = s.charAt(i); if (c == ' ' || c == '\t' || c == '\n' || c == '\r') i++; else break; } }

    Object value(int depth) {
      if (depth > 512) throw err("nested too deeply");
      if (i >= s.length()) throw err("unexpected end");
      char c = s.charAt(i);
      switch (c) {
        case '{': return object(depth);
        case '[': return array(depth);
        case '"': return string();
        case 't': lit("true"); return Boolean.TRUE;
        case 'f': lit("false"); return Boolean.FALSE;
        case 'n': lit("null"); return null;
        default:
          if (c == '-' || (c >= '0' && c <= '9')) return number();
          throw err("unexpected '" + c + "'");
      }
    }

    void lit(String w) { if (!s.startsWith(w, i)) throw err("expected " + w); i += w.length(); }

    Map<String, Object> object(int depth) {
      Map<String, Object> m = new LinkedHashMap<>();
      i++; ws();
      if (i < s.length() && s.charAt(i) == '}') { i++; return m; }
      for (;;) {
        ws();
        if (i >= s.length() || s.charAt(i) != '"') throw err("expected a key");
        String k = string();
        ws();
        if (i >= s.length() || s.charAt(i) != ':') throw err("expected ':'");
        i++; ws();
        m.put(k, value(depth + 1));
        ws();
        if (i >= s.length()) throw err("unexpected end");
        char c = s.charAt(i++);
        if (c == '}') return m;
        if (c != ',') throw err("expected ',' or '}'");
      }
    }

    List<Object> array(int depth) {
      List<Object> a = new ArrayList<>();
      i++; ws();
      if (i < s.length() && s.charAt(i) == ']') { i++; return a; }
      for (;;) {
        ws();
        a.add(value(depth + 1));
        ws();
        if (i >= s.length()) throw err("unexpected end");
        char c = s.charAt(i++);
        if (c == ']') return a;
        if (c != ',') throw err("expected ',' or ']'");
      }
    }

    String string() {
      i++;
      StringBuilder sb = new StringBuilder();
      while (i < s.length()) {
        char c = s.charAt(i++);
        if (c == '"') return sb.toString();
        if (c == '\\') {
          if (i >= s.length()) break;
          char e = s.charAt(i++);
          switch (e) {
            case '"': sb.append('"'); break;
            case '\\': sb.append('\\'); break;
            case '/': sb.append('/'); break;
            case 'b': sb.append('\b'); break;
            case 'f': sb.append('\f'); break;
            case 'n': sb.append('\n'); break;
            case 'r': sb.append('\r'); break;
            case 't': sb.append('\t'); break;
            case 'u':
              if (i + 4 > s.length()) throw err("bad \\u escape");
              try { sb.append((char) Integer.parseInt(s.substring(i, i + 4), 16)); } catch (NumberFormatException x) { throw err("bad \\u escape"); }
              i += 4;
              break;
            default: throw err("bad escape");
          }
        } else if (c < 0x20) {
          throw err("control character in string");
        } else {
          sb.append(c);
        }
      }
      throw err("unterminated string");
    }

    Object number() {
      int start = i;
      if (s.charAt(i) == '-') i++;
      boolean frac = false;
      while (i < s.length()) {
        char c = s.charAt(i);
        if (c >= '0' && c <= '9') i++;
        else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') { frac = true; i++; }
        else break;
      }
      String n = s.substring(start, i);
      try {
        if (!frac) {
          BigInteger b = new BigInteger(n);
          return b.bitLength() < 64 ? (Object) b.longValue() : b;
        }
        double d = Double.parseDouble(n);
        return Double.isInfinite(d) ? new BigDecimal(n) : (Object) d;
      } catch (NumberFormatException x) {
        throw err("bad number " + n);
      }
    }
  }

  // ---------------------------------------------------------------- helpers for models

  @SuppressWarnings("unchecked")
  static Map<String, Object> asMap(Object o) {
    return o instanceof Map ? (Map<String, Object>) o : Collections.emptyMap();
  }

  @SuppressWarnings("unchecked")
  static List<Object> asList(Object o) {
    return o instanceof List ? (List<Object>) o : Collections.emptyList();
  }
}
