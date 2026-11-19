# Callio SDKs

Callio puts voice calls, chat and live location inside your own mobile app. Your users talk to each other, or to
your contact centre, without ever sharing a phone number. These SDKs connect your app to the Callio platform.

| Platform | Install | Package |
|---|---|---|
| iOS (Swift Package Manager) | Add `https://github.com/iamakkshay/callio-sdk`, products `InCallSDK` and `InCallUI` | [ios/](ios) |
| iOS (CocoaPods) | `pod 'InCallSDK'`, and `pod 'InCallUI'` for the ready-made screens | [ios/](ios) |
| Android | `implementation("com.github.iamakkshay.callio-sdk:incall-sdk:0.3.3")` from JitPack | [android/](android) |
| Android UI (Compose) | `implementation("com.github.iamakkshay.callio-sdk:incall-ui:0.3.3")` | [android-ui/](android-ui) |
| Flutter | `flutter pub add incall_flutter` | [flutter/](flutter) |
| React Native | `npm install @apurohit2/callio-react-native` | [react-native/](react-native) |
| Web (browser) | `npm install @apurohit2/callio-web` | npm |

**Server SDKs** call the Callio REST API from your backend: create users, mint app tokens, read call records, and
verify webhooks.

| Language | Install | Package |
|---|---|---|
| Node.js | `npm install @apurohit2/callio-server` | [server/node/](server/node) |
| Python | `pip install callio-server` | [server/python/](server/python) |
| Go | `go get github.com/iamakkshay/callio-sdk/server/go@v0.1.0` | [server/go/](server/go) |
| Java, PHP, .NET | Build from source for now | [server/](server) |

The app SDKs share one version (see [VERSION](VERSION)) and follow semantic versioning. Changes are listed in
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
