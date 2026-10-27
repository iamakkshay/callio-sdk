# incall_flutter

Callio in-app voice calling, chat and live location for Flutter, over SIP and WebRTC. The plugin bridges to the native iOS (`InCallSDK`) and Android (`com.ngx.incall`) SDKs via platform
channels.

```dart
final incall = InCall.instance;

incall.events.listen((e) {
  switch (e) {
    case RegistrationChanged(:final state): /* .connecting/.registered/.offline */
    case IncomingCall(:final from): /* ring UI */
    case CallStateChanged(:final state): /* connected, ended, ... */
    case MessageReceived(:final message): /* chat bubble */
    case QualityUpdated(:final quality): /* rtt/jitter/loss */
    case CallFailed(:final message): /* surface error */
  }
});

// The SDK never logs in — your backend mints the short-lived token.
await incall.start(baseUrl: 'https://platform.example.com', tokenProvider: () => myBackend.freshToken());

final call = await incall.dial('1005');   // calls work once native WebRTC is linked
await incall.sendText('1005', 'Hi from Flutter');
final history = await incall.callHistory();
await incall.registerPush(fcmOrVoipToken);
```

## Install

```sh
flutter pub add incall_flutter
```

- **iOS:** the plugin pulls `InCallSDK` from CocoaPods. Add Push Notifications and Background Modes (Voice over IP)
  to your app, and `NSMicrophoneUsageDescription` to Info.plist.
- **Android:** the plugin pulls the native SDK from JitPack (`com.github.iamakkshay.callio-sdk:incall-sdk`). Add
  `maven { url 'https://jitpack.io' }` to your app's repositories if your settings restrict them.

## Example

`example/` is a runnable demo: it signs in, dials and chats. Set `_baseUrl` and the account to your Callio
platform, then `flutter run` on a device.

## Layout
```
lib/            Dart API (InCall, Call, models, events)
android/        Kotlin MethodChannel/EventChannel bridge → com.ngx.incall
ios/            Swift bridge → InCallSDK
example/        runnable demo app
```
