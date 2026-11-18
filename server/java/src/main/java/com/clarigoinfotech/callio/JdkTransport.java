package com.clarigoinfotech.callio;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/** The default transport on {@code java.net.http.HttpClient}, with redirects disabled. */
public final class JdkTransport implements Transport {
  private final HttpClient client;

  public JdkTransport() {
    this(HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build());
  }

  /**
   * Use your own client (proxy, TLS settings…). It must be built with {@code followRedirects(Redirect.NEVER)}:
   * a redirect would carry the API key to another host.
   */
  public JdkTransport(HttpClient client) {
    if (client.followRedirects() != HttpClient.Redirect.NEVER) {
      throw new IllegalArgumentException("Callio: the HttpClient must use followRedirects(HttpClient.Redirect.NEVER)");
    }
    this.client = client;
  }

  @Override
  public Response send(Request r) throws IOException, InterruptedException {
    HttpRequest.Builder b = HttpRequest.newBuilder(r.uri).timeout(r.timeout)
        .method(r.method, r.body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofByteArray(r.body));
    for (Map.Entry<String, String> h : r.headers.entrySet()) b.header(h.getKey(), h.getValue());
    HttpRequest req = b.build();
    if (r.stream) {
      // The request timeout covers receiving the headers; the body is then read at the caller's pace.
      HttpResponse<InputStream> res = client.send(req, HttpResponse.BodyHandlers.ofInputStream());
      return new Response(res.statusCode(), res.headers().map(), res.body());
    }
    // A buffered response: the timeout covers the whole exchange, body included.
    CompletableFuture<HttpResponse<byte[]>> f = client.sendAsync(req, HttpResponse.BodyHandlers.ofByteArray());
    try {
      HttpResponse<byte[]> res = f.get(r.timeout.toMillis(), TimeUnit.MILLISECONDS);
      return new Response(res.statusCode(), res.headers().map(), new ByteArrayInputStream(res.body()));
    } catch (TimeoutException e) {
      f.cancel(true);
      throw new HttpTimeoutException("request timed out");
    } catch (InterruptedException e) {
      f.cancel(true);
      throw e;
    } catch (ExecutionException e) {
      Throwable c = e.getCause();
      if (c instanceof IOException) throw (IOException) c;
      if (c instanceof RuntimeException) throw (RuntimeException) c;
      throw new IOException(c);
    }
  }
}
