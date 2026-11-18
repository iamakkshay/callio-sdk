package com.clarigoinfotech.callio;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/** Call recordings. Every audio or transcript fetch needs a reason, written to the recording's access trail. */
public final class Recordings {
  private final CallioHttp http;

  Recordings(CallioHttp http) { this.http = http; }

  public List<Recording> list(ListRecordingsParams params) {
    Map<String, Object> q = params == null ? Collections.<String, Object>emptyMap() : params.toMap();
    return new Users.Wrap(http.requestObject("GET", "/api/v1/recordings", q, null)).list("recordings", Recording::new);
  }

  public List<Recording> list() { return list(null); }

  public Recording get(String id) {
    return new Recording(Json.asMap(http.requestObject("GET", "/api/v1/recordings/" + Seg.of(id), null, null).get("recording")));
  }

  /**
   * Open the audio as a stream. The reason (at least 5 characters) is required and goes into the recording's
   * access trail. Use try-with-resources.
   */
  public RecordingAudio audio(String id, String reason) {
    String path = "/api/v1/recordings/" + Seg.of(id) + "/audio";
    return new RecordingAudio(http.requestRaw("GET", path, Collections.singletonMap("reason", Seg.reason(reason))));
  }

  /** Stream the audio into {@code out}; returns the number of bytes written. */
  public long download(String id, OutputStream out, String reason) {
    try (RecordingAudio a = audio(id, reason); InputStream in = a.body()) {
      return in.transferTo(out);
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }

  /** Stream the audio straight to a file; returns the number of bytes written. */
  public long download(String id, Path file, String reason) {
    try (RecordingAudio a = audio(id, reason); OutputStream out = Files.newOutputStream(file)) {
      return a.body().transferTo(out);
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }

  /** The transcript; same rules as the audio. NotFoundException while it is still being transcribed. */
  public Transcript transcript(String id, String reason) {
    String path = "/api/v1/recordings/" + Seg.of(id) + "/transcript";
    return new Transcript(Json.asMap(http.requestObject("GET", path, Collections.singletonMap("reason", Seg.reason(reason)), null).get("transcript")));
  }
}
