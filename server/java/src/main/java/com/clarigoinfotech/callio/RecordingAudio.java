package com.clarigoinfotech.callio;

import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.util.OptionalLong;

/** An open audio download (stereo Ogg/Opus, caller left). Read {@link #body()} and close it promptly. */
public final class RecordingAudio implements Closeable {
  private final Transport.Response response;
  private final String contentType;
  private final OptionalLong contentLength;

  RecordingAudio(Transport.Response response) {
    this.response = response;
    String ct = response.header("Content-Type");
    this.contentType = ct == null || ct.isEmpty() ? "audio/ogg" : ct;
    OptionalLong len = OptionalLong.empty();
    String cl = response.header("Content-Length");
    if (cl != null) {
      try { len = OptionalLong.of(Long.parseLong(cl.trim())); } catch (NumberFormatException ignore) { /* unknown */ }
    }
    this.contentLength = len;
  }

  public InputStream body() { return response.body; }

  public String contentType() { return contentType; }

  public OptionalLong contentLength() { return contentLength; }

  @Override public void close() throws IOException { response.close(); }
}
