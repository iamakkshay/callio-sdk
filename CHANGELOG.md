# Callio SDK changelog

All SDKs (iOS, Android, Flutter, React Native) share one version, kept in `VERSION`. Versions follow
[semantic versioning](https://semver.org): a **major** bump breaks apps, a **minor** adds features, a **patch** fixes.

## 0.2.3
Android and iOS, tested on a real Android phone against the platform:
- Ringing when the app is closed: the call server now holds a call while the push wakes the app, and delivers it
  when the app reconnects (needs platform 2026-10-27 or later). Answering from the system call screen before the
  call has arrived now waits for it instead of failing.
- Hold and resume renegotiate from the WebRTC connection in both directions (an echoed SDP made the other side drop
  the call). Holding from the app tells the other side.
- A second call while on a call gets "busy" instead of replacing the current one.
- 3-way calls: when the other side adds someone, the SDK follows the call into the conference
  (`onConferenceStarted` / `conferenceDidStart`); invitations arrive as `onConferenceInvite` /
  `didReceiveConferenceInvite`, joined with `joinConference`.
- Audio: voice processing on the microphone (echo cancellation, noise suppression, gain, high-pass) and Opus
  in-band FEC, mono, 32 kbps. Android enters voice-call audio mode for the call.
- Hanging up when the media can't start after the other side answered (it was left in the call); a second answer
  tap is ignored; Android WebRTC set-up runs off the main thread; ICE gathering waits at most 2.5 s.

## 0.2.2
Fixes found testing the Android demo on a real phone (iOS had the same bugs):
- Incoming calls: the SDK now replies 100 Trying and 180 Ringing at once. Before, the call server gave up after
  6 s, so answering did nothing.
- A call cancelled by the caller now stops ringing (CANCEL → 487), and a remote hang-up is reported.
- Chat: sending answers the proxy's authentication challenge (every message failed with 407 before), and
  received messages are acknowledged with 200 OK.
- Replies to the call server carry every Via (and Record-Route), so they route back to the caller.
- Each call and message gets its own Call-ID (calls reused one, which broke the second call).
- `dial()` returns at once and reports Ringing, Connected, or why the call ended (busy, declined, no answer);
  hanging up a call that hasn't been answered cancels it.
- Verified against the live call server: chat both ways, ringing past 6 s, answer, hang-up, cancel, decline.

## 0.2.1
- Android: `InCallClient` now uses WebRTC calls by default (0.2.0 only registered and chatted unless you wired
  the transport yourself).
- New: native Android demo app in `android-demo/`. Sign in, see contacts and presence, call, chat and share
  location, using the ready-made screens. CI builds an installable APK.

## 0.2.0
- Calls survive network changes (ICE restart, up to 15 s).
- Pre-call network test (`preCallTest()`): server, signalling, microphone, STUN and TURN.
- Support calls: entry points with overflow, escalation from chat, interaction ids.
- SDKs send `X-SDK-Version`; the session carries `sdk.minVersion` / `sdk.latest` so apps can prompt an update.
- Caller context to the contact centre: app version, language, order reference.
- New: React Native wrapper `@clarigoinfotech/callio-react-native` over the native iOS and Android SDKs.
- New: native call UI inside the SDKs. iOS `InCallCallKit` covers CallKit, PushKit and the audio-session handoff
  to WebRTC. Android `InCallTelecom` covers the self-managed ConnectionService and a full-screen CallStyle
  notification. Outgoing calls go through the system too.
- New: audio routing (`client.audio`: available / current / set) and route-change events on iOS, Android, Flutter
  (`setAudioRoute`, `AudioRouteChanged`) and React Native (`setAudioRoute`, `audioRoute`).
- New: prebuilt, themeable screens:
  - iOS `InCallUI`: SwiftUI `CallScreen`, `IncomingCallView`, `ChatView`, `ChatBubble`.
  - Android `incall-ui`: Compose `CallScreen`, `IncomingCallScreen`, `ChatScreen`, `ChatBubble`.
  - Both have English and Arabic with right-to-left layout, and a theme for colours, corner radius and font.
- New (iOS): `CallQuality` has a public initializer.
- New: presence (`refreshPresence`, `startPresenceUpdates`, `presenceDidChange` / `onPresenceChanged`).
- New: `disconnectInBackground` (default on): no signalling socket while the app is in the background without a call; pushes ring it (NFR-13).
- New (iOS): `InCallClient.addObserver`, so components can follow calls without replacing the app's delegate.
- Breaking (Flutter): `InCallEvent` gained `AudioRouteChanged`; exhaustive `switch`es over events need a case for it.

## 0.1.0
- First release: register, 1:1 voice/video calls, chat, location sharing, push wake-up.
