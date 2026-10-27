# Callio SDKs

Callio puts voice calls, chat and live location inside your own mobile app. Your users talk to each other, or to
your contact centre, without ever sharing a phone number. These SDKs connect your app to the Callio platform.

| Platform | Install | Package |
|---|---|---|
| iOS (Swift Package Manager) | Add `https://github.com/iamakkshay/callio-sdk`, products `InCallSDK` and `InCallUI` | [ios/](ios) |
| iOS (CocoaPods) | `pod 'InCallSDK'`, and `pod 'InCallUI'` for the ready-made screens | [ios/](ios) |
| Android | `implementation("com.github.iamakkshay.callio-sdk:incall-sdk:0.2.2")` from JitPack | [android/](android) |
| Android UI (Compose) | `implementation("com.github.iamakkshay.callio-sdk:incall-ui:0.2.2")` | [android-ui/](android-ui) |
| Flutter | `flutter pub add incall_flutter` | [flutter/](flutter) |
| React Native | `npm install @clarigoinfotech/callio-react-native` | [react-native/](react-native) |

All SDKs share one version (see [VERSION](VERSION)) and follow semantic versioning. Changes are listed in
[CHANGELOG.md](CHANGELOG.md).

## Android: add JitPack

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories { google(); mavenCentral(); maven("https://jitpack.io") }
}
```

## Quick start (iOS)

```swift
import InCallSDK

let config = InCallConfig(baseURL: URL(string: "https://api.your-callio-host.example")!) {
    try await myBackend.freshCallioToken()      // your server mints a short-lived token; the SDK never logs in
}
let client = InCallClient(config: config)
client.delegate = self
try await client.start()
let call = try await client.dial(contact)
```

## Quick start (Android)

```kotlin
import com.ngx.incall.*

val config = InCallConfig(baseUrl = "https://api.your-callio-host.example") { myBackend.freshCallioToken() }
val client = InCallClient(context, config)
scope.launch {
    client.start()
    val call = client.dial(contact)
}
```

A complete native Android app using the SDK is in [android-demo/](android-demo); CI builds an installable APK.

Native ringing when the app is closed (CallKit on iOS, Telecom on Android) needs a few lines in your app: see
[EXAMPLES.md](EXAMPLES.md). The full API model is in [docs/SDK_API_CONTRACT.md](docs/SDK_API_CONTRACT.md).

## Licence

Proprietary, © 2026 Clarigo Infotech. You may use these SDKs only to connect your app to the Callio platform under
an agreement with Clarigo Infotech. See [LICENSE](LICENSE).
