# incall_flutter

Callio in-app voice calls, chat and location for Flutter (FR-SDK-02). The plugin wraps the native Callio SDKs, so a
Flutter app gets the same SIP-over-WSS signalling, WebRTC media, CallKit / ConnectionService call UI and push
handling as a native app:

- Android: `com.ngx.incall` (the `incall-sdk` library, with the WebRTC media layer and `InCallTelecom`)
- iOS: `InCallSDK` (with WebRTC and `InCallCallKit`)

The Dart API mirrors [`docs/SDK_API_CONTRACT.md`](../../../docs/SDK_API_CONTRACT.md). There are two libraries:

| Import | What you get |
|---|---|
| `package:incall_flutter/incall_flutter.dart` | Headless API: `InCall`, models, events, `CallController`, `ChatController` |
| `package:incall_flutter/incall_ui.dart` | The above, plus optional ready-made screens in the Callio Jade theme |

## Status

| | State |
|---|---|
| Dart API, events, controllers, widgets | Done. `flutter analyze` clean, 50 unit and widget tests (`flutter test`) with a mocked platform channel |
| Android bridge (`android/`) | Done for every Dart method and event. Compiles and links in `flutter build apk --debug` for the example, both against the released SDK from JitPack and against this repository's sources. The APK contains the WebRTC transport, libwebrtc, the ConnectionService and the permissions |
| iOS bridge (`ios/`) | Done for every Dart method and event. Typechecked with `swiftc` against `InCallSDK` built as a separate module, iOS API through Mac Catalyst, with a stub of Flutter's API. **Not built with Xcode or CocoaPods**: neither was available when this was written |
| Calls and chat on a real device | **Not verified yet** for the Flutter plugin. The native SDKs underneath are the same ones the native apps use |
| Push from a killed app | iOS: handled natively by PushKit + CallKit once `start()` has run at launch (not verified). Android: not wired for Flutter yet (see [Push](#push)) |

What is left before production: run the example on an Android phone and an iPhone against a lab platform
(register, call both ways, mute, hold, speaker, keypad, chat), build the iOS example with Xcode, and wire the
Android killed-app push path.

## Install

The plugin is not on pub.dev yet. Use a path or git dependency.

```yaml
# pubspec.yaml
dependencies:
  incall_flutter:
    path: ../ngx-p2p/sdk/flutter/incall_flutter      # a checkout of this repository
  # or, from the released SDK repository (the plugin lives in flutter/ there):
  # incall_flutter:
  #   git:
  #     url: https://github.com/iamakkshay/callio-sdk.git
  #     path: flutter
  #     ref: 0.3.2
```

Needs Flutter 3.27 or newer, Android 7 (API 24) or newer, iOS 15 or newer.

### Android

Nothing to add to Gradle. The plugin depends on `com.github.iamakkshay.callio-sdk:incall-sdk:<plugin version>` and
adds the JitPack repository to the app's build, restricted with `exclusiveContent` to the
`com.github.iamakkshay.callio-sdk` group: JitPack can't supply any other dependency of your app. (If your
`settings.gradle` uses `dependencyResolutionManagement` with `FAIL_ON_PROJECT_REPOS`, add the same filtered
repository there instead:)

```groovy
exclusiveContent {
    forRepository { maven { url 'https://jitpack.io' } }
    filter { includeGroup 'com.github.iamakkshay.callio-sdk' }
}
```

Publishing the SDK to Maven Central, so JitPack isn't needed at all, is planned.

- `minSdk` must be at least 24 (`android/app/build.gradle.kts`: `minSdk = maxOf(24, flutter.minSdkVersion)`).
- Permissions are merged from the plugin's manifest: `INTERNET`, `RECORD_AUDIO`, `MANAGE_OWN_CALLS`,
  `USE_FULL_SCREEN_INTENT`, `POST_NOTIFICATIONS`, `BLUETOOTH_CONNECT`, `MODIFY_AUDIO_SETTINGS`,
  `ACCESS_NETWORK_STATE`. So are the self-managed `ConnectionService` and the notification action receiver.
- At runtime, ask for the microphone (and, on Android 13+, notifications) before the first call:
  `await InCall.instance.requestPermissions()`.
- Release builds talk to the platform over https. For a lab server on plain http, allow cleartext in debug only
  (the example does this in `android/app/src/debug/AndroidManifest.xml`).
- The SDK's R8 rules ship inside the AAR, so minified release builds keep the WebRTC transport.

### iOS

`InCallSDK` is not on the CocoaPods trunk, so name its source in `ios/Podfile`, inside `target 'Runner' do`:

```ruby
platform :ios, '15.0'

target 'Runner' do
  use_frameworks!
  pod 'InCallSDK', :git => 'https://github.com/iamakkshay/callio-sdk.git', :tag => '0.3.2'
  # or this repository's sources: pod 'InCallSDK', :path => '<path to ngx-p2p>/sdk/ios'
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
end
```

Then set the Runner target's iOS deployment target to 15.0, and in `ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Used for voice calls.</string>
<key>UIBackgroundModes</key>
<array><string>audio</string><string>voip</string></array>
```

In Xcode, add the **Push Notifications** capability (VoIP pushes). CallKit needs no setup: with
`nativeCallUi: true` (the default) the plugin creates `InCallCallKit` and registers for VoIP pushes, and the VoIP
token is registered with the platform automatically.

## Quick start (headless)

```dart
import 'package:incall_flutter/incall_flutter.dart';

final incall = InCall.instance;

// The SDK never logs anyone in. Your backend authenticates the user and mints a short-lived token
// (Callio: POST /api/v1/tokens with your tenant API key). The SDK calls this on start and when the token expires.
await incall.requestPermissions();
await incall.start(baseUrl: 'https://callio.example.com', tokenProvider: () => myBackend.callioToken());

incall.events.listen((e) {
  switch (e) {
    case RegistrationChanged(:final state): /* connecting / registered / offline */
    case IncomingCall(:final callId, :final from): /* ring */
    case CallStateChanged(:final status, :final reason): /* initiating ... connected ... ended(reason) */
    case MessageReceived(:final peerSip, :final message): /* chat */
    case CallFailed(:final errorCode, :final message): /* surface it */
    default:
  }
});

final call = await incall.dial('1005');          // extension or directory username
await incall.setMuted(true);
await incall.setAudioRoute('speaker');
await incall.sendDtmf('5');
await incall.hangup();

await incall.sendText('1005', 'On my way');
await incall.sendLocation('1005', const SharedLocation(lat: 24.71, lng: 46.67, label: 'Gate 3'));
final history = await incall.callHistory();
final session = await incall.session();        // features, directory, user type
```

Errors: methods throw `InCallException` with a stable `code` (`notRegistered`, `micPermission`, `peerUnreachable`,
`busy`, `tokenExpired`, `featureDisabled`, `network`, `mediaFailed`, `noActiveCall`, `invalidArgument`, `unknown`).

### API

| Area | Methods |
|---|---|
| Session | `start`, `stop`, `session`, `registrationState`, `registrationChanges`, `requestPermissions`, `nativeSdkVersion` |
| Calls | `dial`, `answer`, `decline`, `cancel`, `hangup`, `setMuted`, `setHold`, `sendDtmf`, `setAudioRoute`, `audioRoutes`, `transfer`, `joinConference`, `currentCall` |
| Chat and location | `sendText`, `sendLocation`, `setTyping`, `messages` |
| Presence | `refreshPresence`, `startPresenceUpdates`, `stopPresenceUpdates` |
| History and push | `callHistory`, `registerPush`, `unregisterPush`, `handlePush` |

Events: `RegistrationChanged`, `IncomingCall`, `CallStateChanged`, `QualityUpdated`, `MessageReceived`,
`MessageStatusChanged`, `AudioRouteChanged`, `PresenceChanged`, `ConferenceInviteReceived`, `ConferenceStarted`,
`CallFailed`. `InCallEvent` is sealed, so a `switch` without `default` must handle each of them.

`CallController` (one call: status, mute, hold, route, quality, timer, and the controls) and `ChatController`
(one conversation: messages with delivery status, optimistic send, typing) are `ChangeNotifier`s built on
these events. Use them for your own UI.

## Ready-made widgets

```dart
import 'package:incall_flutter/incall_ui.dart';

final navigatorKey = GlobalKey<NavigatorState>();

MaterialApp(
  navigatorKey: navigatorKey,
  theme: CallioTheme.light(),
  darkTheme: CallioTheme.dark(),
  // Shows the incoming-call screen, then the in-call screen once answered, wherever the user is.
  builder: (context, child) => CallioCallListener(navigatorKey: navigatorKey, child: child!),
  home: const HomePage(),
);

// Dial and show the in-call screen (Calling, Ringing, then the timer):
await CallioCalls.dial(Navigator.of(context), '1005');

// A conversation:
Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChatScreen(peerSipUser: '1005', title: 'Vineet')));
```

| Widget | What it is |
|---|---|
| `IncomingCallScreen` | Caller, pulsing avatar, Answer and Decline. Closes itself if the caller hangs up |
| `InCallScreen` | Status and timer, quality bars, Mute, Keypad (DTMF), Speaker (or an output picker when Bluetooth is there), Hold, optional Chat, End. Shows the end reason, then closes |
| `CallFlowScreen` | Both of the above on one route, owning the `CallController` |
| `ChatView` / `ChatScreen` | Bubbles with sending / sent / delivered / read / failed, location cards, composer with typing notifications, optional Share location (you supply the location) |
| `CallioDialPad`, `CallQualityIndicator`, `CallControlButton`, `CallioAvatar` | The building blocks |
| `CallioTheme`, `CallioColors`, `CallioCallStyle` | Jade light and dark Material 3 themes; call-screen colours as a `ThemeExtension` (the widgets fall back to Jade under any app theme) |
| `CallioStrings` | All widget text, English by default. Pass your own (for example Arabic); layouts use directional insets for right-to-left |

Icons are Material outlined line icons; there is no emoji. Animations respect the system's reduce-motion setting.

Fonts: by default the platform font is used and nothing is downloaded. To use Plus Jakarta Sans and Sora, either
bundle them as assets and pass `CallioTheme.light(fontFamily: 'PlusJakartaSans', displayFontFamily: 'Sora')`, or,
if your app already uses the `google_fonts` package, pass `GoogleFonts.plusJakartaSans().fontFamily` and
`GoogleFonts.sora().fontFamily`. That opt-in is yours; the plugin does not depend on `google_fonts`.

## Push

- **iOS**: VoIP pushes go through PushKit to CallKit inside the native SDK. Call `InCall.instance.start(...)` early in
  `main()` when the user is already signed in (with a token provider that works without UI), so the PushKit
  registry is in place when iOS launches the app for a push. `handlePush` returns false on iOS.
- **Android, app running**: get the FCM token with `firebase_messaging` and call `registerPush(token)`. Hand data
  messages to `InCall.instance.handlePush(message.data)`: an incoming-call push rings through the ConnectionService
  with the full-screen call notification.
- **Android, app killed**: not wired for Flutter yet. Ringing from a killed state needs a `FirebaseMessagingService`
  in the host app that starts an `InCallClient` with a native token source and calls
  `InCallTelecom.install` / `InCallTelecom.reportIncoming` (see `sdk/android/examples/IncallTelecom.kt`). The SDK's
  classes are on the app's classpath (`api` dependency) for that. Until then, keep the app's process alive for
  calls, or start with `disconnectInBackground: false` while testing.

## Example app

`example/` signs in with a token from a configurable backend, shows the registration state, lists the directory
with presence, dials, receives calls (ready-made screens), chats, and shows call history.

```sh
cd example
flutter run                                   # Android emulator: the platform at http://10.0.2.2:8080
flutter run --dart-define=CALLIO_BASE_URL=https://callio.example.com \
            --dart-define=CALLIO_TOKEN_URL=https://your-backend.example.com/callio-token
```

The token URL gets a JSON POST of `{username, password, tenant}` and must answer `{"token": "..."}`. Left empty, it
uses the platform's development endpoint `<base URL>/api/login`, which works against a lab install. On iOS, run
`flutter run` on a Mac with Xcode and CocoaPods (the Podfile points at this repository's `sdk/ios`).

## Developing the SDK

Compile against this repository's native Android sources instead of the JitPack release (for native changes that
are not released yet): add `callio.localSdk=true` to the app's `android/gradle.properties`, or build with
`flutter build apk --android-project-arg=callio.localSdk=true`. An absolute path to `sdk/android` also works.

```sh
flutter analyze && flutter test                 # package
(cd example && flutter analyze && flutter test && flutter build apk --debug)
sh ../../scripts/android-jvm-check.sh           # Android SDK + this bridge with kotlinc, plus the SDK's unit tests
```

## Layout

```
lib/incall_flutter.dart   headless API
lib/incall_ui.dart        widgets + headless API
lib/src/                  InCall, models, controllers, ui/
android/                  Kotlin MethodChannel / EventChannel bridge to com.ngx.incall
ios/                      Swift bridge to InCallSDK
example/                  runnable demo app
test/                     unit and widget tests (mocked platform channel)
```
