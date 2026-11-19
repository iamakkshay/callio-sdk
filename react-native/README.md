# @clarigoinfotech/callio-react-native

Callio calling, chat and location for React Native (FR-SDK-02). It wraps the native iOS (`InCallSDK`) and Android
(`com.ngx.incall`) SDKs, so calls get the same media, push wake-up and CallKit / ConnectionService behaviour as
native apps.

```sh
npm install @clarigoinfotech/callio-react-native
```

**iOS.** The native SDK (`InCallSDK`) is not on the CocoaPods trunk. Pin its source in `ios/Podfile`,
inside your app target and before `use_native_modules!`, so CocoaPods never looks the name up on trunk:

```ruby
target 'MyApp' do
  pod 'InCallSDK', :git => 'https://github.com/iamakkshay/callio-sdk.git', :tag => '0.3.1'
  # or this repository's sources: pod 'InCallSDK', :path => '<path to ngx-p2p>/sdk/ios'
  config = use_native_modules!
  # ...
end
```

Then run `cd ios && pod install`. Without the pin, `pod install` would resolve `InCallSDK` from the public
trunk, where anyone could register that name.

**Android.** The native SDK `com.github.iamakkshay.callio-sdk:incall-sdk` comes from JitPack. The module's
build adds JitPack only for the `com.github.iamakkshay.callio-sdk` group, so JitPack can't supply any other
dependency of your app. If your `settings.gradle` uses `dependencyResolutionManagement` with
`FAIL_ON_PROJECT_REPOS`, add the same filtered repository there:

```groovy
exclusiveContent {
    forRepository { maven { url 'https://jitpack.io' } }
    filter { includeGroup 'com.github.iamakkshay.callio-sdk' }
}
```

**Transport security.** `baseUrl` must be `https://`, and the server's SIP socket must be `wss://`.
For a lab server on plain http, pass `allowInsecureTransport: true` to `InCall.start` in a debug build
only.

```ts
import { InCall } from '@clarigoinfotech/callio-react-native';

await InCall.start({
  baseUrl: 'https://api.example.sa',
  tokenProvider: () => myBackend.callioToken(),   // your server calls POST /api/v1/tokens
});
const off = InCall.on('incomingCall', ({ callId, from }) => showIncoming(from.displayName));
InCall.on('callState', ({ state, reason }) => setCallState(state, reason));   // reason when ended: no-answer, busy, declined, …

const call = await InCall.dial('1002');
await call.setMuted(true);
await InCall.sendText('1002', 'On my way');
await InCall.sendLocation('1002', { lat: 24.71, lng: 46.67 });
await InCall.registerPush(voipOrFcmToken);
```

Events: `registration`, `incomingCall`, `callState`, `quality`, `message`, `failure` (types in `src/core.ts`).

## How it fits together

| Layer | File |
|---|---|
| JS API (typed, no react-native imports, unit-tested) | `src/core.ts` |
| Wiring to the native module | `src/index.ts` |
| iOS bridge | `ios/CallioInCall.swift` + `ios/CallioInCall.m` |
| Android bridge | `android/src/main/java/com/ngx/incall/rn/` |

**Tokens.** The native SDK asks for a token whenever it needs one. Native code emits `tokenRequest`, the JS layer
calls your `tokenProvider` and answers with `provideToken`. If nothing answers within 20 s, the SDK reports
`tokenExpired`.

## Tests

`npm test` runs the JS layer against a mock native module (Node 22.6+).

The iOS bridge is typechecked against the real `InCallSDK` sources, with a stub for React's API:

```sh
xcrun swiftc -typecheck <InCallSDK sources> <React stub> ios/CallioInCall.swift
```

The Android bridge needs a React Native host app (JDK 17) to compile.
