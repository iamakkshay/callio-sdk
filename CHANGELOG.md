# Callio SDK changelog

All SDKs (iOS, Android, Flutter, React Native) share one version, kept in `VERSION`. Versions follow
[semantic versioning](https://semver.org): a **major** bump breaks apps, a **minor** adds features, a **patch** fixes.

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
