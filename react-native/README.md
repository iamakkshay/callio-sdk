# @apurohit2/callio-react-native

Callio calling, chat and location for React Native (FR-SDK-02). It wraps the native iOS (`InCallSDK`) and Android
(`com.ngx.incall`) SDKs, so calls get the same media, push wake-up and CallKit / ConnectionService behaviour as
native apps.

```sh
npm install @apurohit2/callio-react-native
```

> **Private package.** Install it with your organisation's SDK install token (console → Security & data → SDK install
> tokens). Add two lines to your app's `.npmrc`, where `<platform>` is your Callio address, and set `CALLIO_SDK_TOKEN`
> in your environment or build server (keep it secret; don't commit it):
>
> ```ini
> @apurohit2:registry=https://<platform>/npm/
> //<platform>/npm/:_authToken=${CALLIO_SDK_TOKEN}
> ```

**iOS.** The native SDK (`InCallSDK`) is not on the CocoaPods trunk. Pin its source in `ios/Podfile`,
inside your app target and before `use_native_modules!`, so CocoaPods never looks the name up on trunk:

```ruby
target 'MyApp' do
  pod 'InCallSDK', :git => 'https://github.com/iamakkshay/callio-sdk.git', :tag => '0.3.3'
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
import { InCall } from '@apurohit2/callio-react-native';

await InCall.start({
  baseUrl: 'https://api.example.sa',
  tokenProvider: () => myBackend.callioToken(),   // your server calls POST /api/v1/tokens
});
const off = InCall.on('incomingCall', ({ callId, from }) => showIncoming(from.displayName));
InCall.on('callState', ({ state, reason }) => setCallState(state, reason));   // reason when ended: no-answer, busy, declined, …

const call = await InCall.dial('1002');
await call.setMuted(true);
await InCall.sendText('1002', 'On my way');
await InCall.sendLocation('1002', { lat: 24.71, lng: 46.67, label: 'Gate 3' });
await InCall.registerPush(voipOrFcmToken);
```

### Messages to someone who is offline

`sendText` and `sendLocation` work whether or not the other person's app is connected. If they're offline, the
platform holds the message and delivers it when they're back, and you get a `messageStatus` event with
`status: 'queued'` for that message id. Messages held for this user arrive as ordinary `message` events when the
SDK connects.

```ts
const id = await InCall.sendText('1002', 'Your order is outside');
InCall.on('messageStatus', ({ messageId, status }) => {
  if (messageId === id && status === 'queued') showNote("Will deliver when they're online");
});
```

### Adding someone to a call (3-way) and handing a call over

During a connected call, `addToCall` brings a third person in, for example a rider adding the support team. The
person you're talking to moves into the 3-way call with you, and the new person is asked to join. Hang up
afterwards to hand the call over (a warm transfer): the other two stay connected.

```ts
await InCall.addToCall(supportSip, 'Support team');   // throws if they're not online; the call is unchanged

// On the support team's phone:
InCall.on('conferenceInvite', async ({ room, from, with: names }) => {
  if (await ask(`${from.displayName} wants you on a call with ${names.join(' and ')}`)) {
    await InCall.joinConference(room, from.sipUser);
  }
});

// On the customer's phone, the call moves into the 3-way call by itself:
InCall.on('conferenceStarted', ({ callId }) => showTitle('3-way call'));
```

3-way calls need a conference server on the platform; without one, `addToCall` reports that the feature is off.

### Events

| Event | Payload |
|---|---|
| `registration` | `{ state }`: `connecting`, `registered`, `offline` |
| `incomingCall` | `{ callId, from }` |
| `callState` | `{ callId, state, reason? }`; `reason` when ended: `ended`, `declined`, `missed`, `no-answer`, `busy`, `unreachable` |
| `quality` | `{ quality: { rttMs, jitterMs, lossPct, mos } }` |
| `message` | `{ peerSip, message }`; `message.text` or `message.location` |
| `messageStatus` | `{ messageId, status }`; `queued` when the person is offline |
| `conferenceInvite` | `{ room, from, with }`; accept with `joinConference(room, from.sipUser)` |
| `conferenceStarted` | `{ callId }`: you followed the other person into a 3-way call |
| `audioRoute` | `{ route }`: `earpiece`, `speaker`, `bluetooth` |
| `failure` | `{ code, message }` |

Types for all of these are in `src/core.ts`.

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
