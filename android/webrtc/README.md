# Android WebRTC media layer (drop-in)

These two files are the **on-device media engine** for Android calls. They're kept out of `src/main`
because they need the **libwebrtc dependency** and only run on a device, so the default build + CI stay
green with signalling-only (register + chat) working. iOS does the same via a `#if canImport(WebRTC)`
guard; Android has no preprocessor, hence this folder.

- [`WebRtcMedia.kt`](WebRtcMedia.kt) — RTCPeerConnection, local mic track, the five SDP/ICE fixes, stats.
- [`WebRtcSignallingSipTransport.kt`](WebRtcSignallingSipTransport.kt) — `SignallingSipTransport` + real
  `dial`/`answer`/`hangup`/`mute`/`hold`, wiring the media to `SipWsClient` (which already does
  REGISTER/INVITE/answer-200).

## To activate calls

1. Add the dependency (any libwebrtc build exposing `org.webrtc`):
   ```kotlin
   implementation("io.github.webrtc-sdk:android:125.6422.07")
   ```
2. Move both files into `src/main/java/com/ngx/incall/`.
3. Make the client default to the WebRTC transport — in `InCallClient`'s public constructor, pass
   `WebRtcSignallingSipTransport(context)` instead of `SignallingSipTransport()`.
4. Grant `RECORD_AUDIO` and request it at runtime; wire the host app's `ConnectionService` (see
   `sdk/EXAMPLES.md`) so the native call UI drives the SDK.

Registration and chat already work without any of this. What remains after wiring is on-device testing
and the TODOs noted in the files (in-dialog BYE, DTMF via `DtmfSender`, true SIP hold re-INVITE, REFER).
