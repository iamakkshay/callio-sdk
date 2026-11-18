package com.clarigoinfotech.callio;

import java.io.ByteArrayInputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.time.Duration;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;

/**
 * The one place a request leaves the process. The default is {@link JdkTransport} (java.net.http); replace it
 * for tests, proxies or instrumentation. A transport must not follow redirects, and must throw
 * {@link java.net.http.HttpTimeoutException} when the timeout passes.
 */
public interface Transport {
  Response send(Request request) throws IOException, InterruptedException;

  /** An outgoing request. */
  final class Request {
    public final String method;
    public final URI uri;
    public final Map<String, String> headers;
    /** Null when there is no body. */
    public final byte[] body;
    /** Per attempt. For a stream, it covers getting the response headers only. */
    public final Duration timeout;
    /** True when the caller streams the response body (recording audio). */
    public final boolean stream;

    public Request(String method, URI uri, Map<String, String> headers, byte[] body, Duration timeout, boolean stream) {
      this.method = method;
      this.uri = uri;
      this.headers = Collections.unmodifiableMap(headers);
      this.body = body;
      this.timeout = timeout;
      this.stream = stream;
    }

    @Override public String toString() { return method + " " + uri.getRawPath(); }
  }

  /** A response. Close it (or read the body to the end) to release the connection. */
  final class Response implements Closeable {
    public final int status;
    private final Map<String, List<String>> headers;
    public final InputStream body;

    public Response(int status, Map<String, List<String>> headers, InputStream body) {
      this.status = status;
      Map<String, List<String>> h = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
      if (headers != null) for (Map.Entry<String, List<String>> e : headers.entrySet()) if (e.getKey() != null) h.put(e.getKey(), e.getValue());
      this.headers = Collections.unmodifiableMap(h);
      this.body = body == null ? new ByteArrayInputStream(new byte[0]) : body;
    }

    /** The first value of a header (case-insensitive), or null. */
    public String header(String name) {
      List<String> v = headers.get(name.toLowerCase(Locale.ROOT));
      return v == null || v.isEmpty() ? null : v.get(0);
    }

    public Map<String, List<String>> headers() { return headers; }

    @Override public void close() throws IOException { body.close(); }
  }
}
