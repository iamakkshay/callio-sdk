# Callio SDK changelog

All SDKs (iOS, Android, Flutter, web engine) share one version, kept in `sdk/VERSION`. Versions follow
[semantic versioning](https://semver.org): a **major** bump breaks apps, a **minor** adds features, a **patch** fixes.
See `docs/SDK_VERSIONING.md` for the support policy.

## 0.3.0
Flutter becomes a first-class platform SDK; https/wss are required unless a development flag is set; tokens can be
bound to one device.

- React Native (Android): the module no longer declares JitPack again when the app already does (the Expo config
  plugin does). Two `exclusiveContent` blocks for one group cancelled out and Gradle found the SDK nowhere.
  New development switch `-Pcallio.mavenLocal=true` resolves a native SDK built locally (`publishToMavenLocal`).
- Flutter: the plugin links the native SDKs. Android depends on `com.github.iamakkshay.callio-sdk:incall-sdk`
  (JitPack, with WebRTC and the Telecom call UI; or this repo's sources with `callio.localSdk=true`); iOS depends on
  the `InCallSDK` pod (new `sdk/ios/InCallSDK.podspec` for path installs).
- Flutter: new methods `cancel`, `transfer`, `audioRoutes`, `session`, `messages`, `joinConference`,
  `refreshPresence`, `startPresenceUpdates`, `stopPresenceUpdates`, `unregisterPush`, `handlePush`,
  `requestPermissions`, `nativeSdkVersion`; `registrationState`, `registrationChanges` and `currentCall` getters;
  `start(disconnectInBackground:, nativeCallUi:)`. With `nativeCallUi` (default on) calls also go to CallKit + PushKit
  on iOS and to the self-managed ConnectionService on Android.
- Flutter: new events `MessageStatusChanged`, `PresenceChanged`, `ConferenceInviteReceived`, `ConferenceStarted`;
  `CallStateChanged` now carries `reason`, `direction`, `peer`, `muted`, `held` and a typed `status`.
- Flutter: errors are `InCallException` with a stable `InCallErrorCode` instead of raw `PlatformException`.
- Flutter: `CallController` and `ChatController` (headless state holders), and optional ready-made widgets in
  `package:incall_flutter/incall_ui.dart`: `IncomingCallScreen`, `InCallScreen`, `ChatView` / `ChatScreen`,
  `CallioCallListener`, `CallioCalls.dial`, keypad, quality indicator, and the Jade `CallioTheme` (light and dark).
- Flutter: runnable example app (token from a configurable backend URL) and unit / widget tests.
- Breaking (Flutter): exhaustive `switch`es over `InCallEvent` need cases for the new events (or a `default`);
  failures throw `InCallException` rather than `PlatformException`. Requires Flutter 3.27+.
- iOS: `Contact` and `SharedLocation` have public initializers (wrappers and apps could not build them before).
- Security (all SDKs): `https://` and `wss://` are required. Plain http / ws need the development flag
  `allowInsecureTransport` (iOS, Android, Flutter, React Native) or `allowInsecure` / `allow_insecure` (server SDKs).
  Breaking for apps that point at an http lab server: set the flag in debug builds.
- Security: `Session.toString()` (Android) and `description` / `debugDescription` / `dump` (iOS) redact the SIP and
  TURN passwords.
- Android and iOS: `sendDtmf` sends RFC 4733 telephone-events through the WebRTC DTMF sender (it was a no-op). Without
  the WebRTC transport, it fails with a media error.
- Web engine: chat attachment URLs are trusted only when they are this origin's `/api/attachments/<32 hex>`. Any other
  URL renders as "File unavailable". A denied or unavailable location now shows an error instead of sending a
  placeholder pin. The diagnostics log records "dtmf: sent" without the digit.
- React Native: `InCallSDK` must be pinned in the app's Podfile (`:git`, `:tag`). The podspec depends on the exact
  SDK version. The JitPack repository added by the RN and Flutter Android builds serves only the
  `com.github.iamakkshay.callio-sdk` group (`exclusiveContent`).
- Flutter example: iOS ATS allows only local networking (`NSAllowsLocalNetworking`), not arbitrary loads.
- Server SDKs (Node, Python): webhooks are verified with `X-Callio-Timestamp` + `X-Callio-Signature: v1=` over
  `timestamp.body`, with a 300 s tolerance (configurable). A delivery without a timestamp is rejected unless
  `allowLegacy` / `allow_legacy` is set. The event `id` is exposed for de-duplication. The old
  `(body, signatureHeader, secret)` call still works but is deprecated. Redirects are refused, an http baseUrl
  needs `allowInsecure`, and `.` / `..` ids are rejected.
- Android: `InCallTelecom.install` keeps the client's audio-route hook, so `onAudioRouteChanged` still fires once
  Telecom is installed.

## 0.2.0
- Calls survive network changes (ICE restart, up to 15 s).
- Pre-call network test (`preCallTest()`): server, signalling, microphone, STUN and TURN.
- Support calls: entry points with overflow, escalation from chat, interaction ids.
- SDKs send `X-SDK-Version`; the session carries `sdk.minVersion` / `sdk.latest` so apps can prompt an update.
- Caller context to the contact centre: app version, language, order reference.
- New: React Native wrapper `@callio/react-native` over the native iOS and Android SDKs.
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
