# Native SDK — Public API Contract (Phase 2)

**Status:** draft contract for review · **Owner:** platform + mobile · **Relates to:** FR-SDK-01..13, FR-CALL-02/03 (CallKit/ConnectionService, VoIP push)

This is the **public API a mobile team implements against** for the iOS (Swift) and Android (Kotlin)
SDKs. It is derived from the working web engine (`public/engine/sip.js`) and the platform's existing
HTTP surface (`services/platform-api`), so the native SDKs and the web client speak to the **same
backend** and behave identically. The web engine is the **reference implementation** of this contract.

Scope here: the **interface** — objects, methods, callbacks, auth, push, errors, versioning. Not the
internal WebRTC/SIP implementation (that's a port of the reference engine, including its five media
fixes).

---

## 1. Principles

- **Headless core + prebuilt UI** (FR-SDK-03). `InCallClient` is the headless API; `InCallUI` is an
  optional, themeable, prebuilt call/chat surface built on top. An integrator can use either.
- **The SDK stores no long-lived secrets** (FR-SDK-04). The **tenant's own backend** authenticates the
  user and mints a short-lived token; the app hands that token to the SDK. The SDK never sees passwords
  and never embeds API keys.
- **One client per signed-in user.** `InCallClient` owns registration, presence, the active call, and
  chat. It is a long-lived singleton for the session.
- **Callbacks on the main thread.** All delegate/listener callbacks are delivered on the main/UI thread;
  SDK methods are safe to call from the main thread and are internally async.
- **Parity with the web client.** Every capability below already works in the reference engine.

---

## 2. Authentication & session (FR-SDK-04 / FR-SDK-13)

The token flow — **the SDK is given a token, it does not log users in**:

```
 Tenant app  ──(user signs in, tenant's own way)──►  Tenant backend
 Tenant backend ──(mints short-lived JWT w/ tenant's jwt_secret)──►  Tenant app
 Tenant app  ──  InCallClient.start(token)  ──►  SDK
 SDK  ──  GET /api/session  (Bearer token)  ──►  Platform  ──►  session blob
 SDK  ──  registers on SIP-over-WSS with the brokered credentials  ──►  ready
```

The JWT claims (already issued by `/api/login` today, which stands in for the tenant backend):
`{ tid, sub, typ: "customer"|"agent", name, iat, exp }`. **User type is in the token and enforced**
(FR-SDK-13) — the UI and routing honour `customer` vs `agent`.

The `/api/session` response the SDK consumes (brokered, never stored beyond the session):

```jsonc
{
  "tenant": "...", "user": "...", "userType": "customer|agent",
  "features": { "calling": true, "chat": true, "location": true, "recording": false },
  "peers": [ { "name", "sipUser", "displayName", "userType" } ],
  "transferTargets": [ ... ], "directory": [ ... ],
  "wss": "wss://...", "realm": "...",
  "sipUser": "...", "authUser": "...", "sipPassword": "...",   // ephemeral, per-session
  "stun": "...", "turn": "...", "turnUser": "...", "turnPassword": "..."  // TURN REST credential
}
```

**Token lifecycle:** the SDK exposes a `tokenProvider` the app supplies; on expiry the SDK calls it to
get a fresh token and re-registers, transparently. The app is the only place a token is minted.

---

## 3. Core API

### `InCallClient`

```swift
// iOS (Swift)
let client = InCallClient(config: InCallConfig(baseURL: URL, tokenProvider: () async -> String))
client.delegate = self
try await client.start()                 // fetch session + register
await client.stop()                      // deregister + tear down

// state
client.registrationState               // .connecting | .registered | .offline
client.features                        // calling / chat / location / recording
client.userType                        // .customer | .agent
client.directory                       // [Contact]
client.currentCall                     // Call?
```

```kotlin
// Android (Kotlin)
val client = InCallClient(context, InCallConfig(baseUrl, tokenProvider = suspend { "..." }))
client.addListener(this)
client.start(); client.stop()
```

### Calls (FR-CALL-01/04/05/09/10)

```swift
let call = try client.dial(contact)            // or dial(sipUser:)
call.answer(); call.hangup(); call.decline(); call.cancel()
call.setMuted(true); call.setHold(true)
call.sendDTMF("5")
call.transfer(to: contact)                     // attended/blind REFER (FR-CALL, transfer)
call.setAudioRoute(.speaker | .earpiece | .bluetooth)   // native routing (FR-CALL-04)

call.state      // .initiating .ringing .connected .onHold .reconnecting .ended(reason)
call.direction  // .incoming | .outgoing
call.peer       // Contact
call.duration   // seconds
call.quality    // { rttMs, jitterMs, lossPct, mos? }   (FR-CALL-11)
```

Mirrors the reference engine's `dial/answer/hangup/cancel/decline/toggleMute/toggleHold/transfer/
sendDTMF`. Call states are exactly the engine's (`initiating, ringing, connected, on-hold,
reconnecting, ended(reason)`), satisfying FR-CALL-05. Unanswered timeout and busy handling (FR-CALL-09/10)
are built in, as in the reference.

### Chat (FR-CHAT-01/02/07) & Location (FR-LOC-01..)

```swift
let thread = client.thread(with: contact)
thread.send(text: "…")
thread.sendLocation(.current)            // or .live(duration:)  — live is roadmap
thread.setTyping(true)
thread.messages                          // [Message] with .status (sending/sent/delivered/read)
```

Chat is 1:1 over the same transport (SIP MESSAGE in the reference); delivery/read receipts and typing
are included. Location shares a pin today; live-location is on the roadmap (see gap matrix).

### Call history (FR-CALL-08)

```swift
let history = try await client.callHistory(limit: 50)   // GET /api/history
// [ { peer, direction, outcome, durationSec, at } ]
```

### Diagnostics (FR-SDK-09)

```swift
client.diagnostics.enable()              // in-memory debug log
let report = client.diagnostics.snapshot()
try await client.diagnostics.upload()    // POST /api/diag
// client.diagnostics.networkPreflight()  — pre-call network test (roadmap)
```

---

## 4. Events (FR-SDK-05)

One delegate (iOS) / listener (Android), all on the main thread:

```swift
protocol InCallClientDelegate {
  func client(_:, registrationDidChange: RegistrationState)
  func client(_:, didReceiveIncomingCall: Call)          // ring UI / CallKit
  func client(_:, callDidChangeState: Call)
  func client(_:, callQualityDidUpdate: CallQuality)
  func client(_:, didReceiveMessage: Message, in: ChatThread)
  func client(_:, messageStatusDidChange: Message)
  func client(_:, peerPresenceDidChange: Contact)        // presence (roadmap depth)
  func client(_:, didReceiveLocation: LocationShare, in: ChatThread)
  func client(_:, didFail: InCallError)
}
```

These map one-to-one to the reference engine's event surface (state changes, incoming call, message in/
status, quality loop, location). Every call/chat lifecycle event is **also** emitted to the platform
(`POST /api/events`) for CDRs/reporting — the SDK does this automatically.

---

## 5. Push — the hard part (FR-CALL-02/03, FR-SDK-06)

This is why a web prototype ≠ the product: reaching a **backgrounded or killed** app and ringing in
**< 5 s** with the **native call UI**.

```
 Register:   app ── client.registerPush(apnsVoIPToken | fcmToken) ──► Platform stores token per user/device
 Incoming:   caller ─► Platform ─► APNs VoIP push / FCM high-priority data ─► device wakes SDK
             SDK ─► CallKit (iOS) / ConnectionService (Android) reports the call ─► native ring UI
             user answers ─► SDK registers on SIP-over-WSS ─► media connects
```

- **iOS:** APNs **VoIP push** → **PushKit** → the SDK **must** report to **CallKit** immediately (OS
  requirement) → native full-screen/lock-screen call UI, native audio routing, call held in the system
  call log.
- **Android:** **FCM high-priority data message** → `ConnectionService` / self-managed `Connection` →
  native-style incoming-call UI, works from killed state.
- **Payload** (platform → push): `{ callId, from: {displayName, userType}, tenant, ttlSec }` — minimal,
  no media, enough to ring and then pull the session.
- **New platform work:** a **push-token registry** (per user+device) and a **push dispatcher** that fires
  on INVITE before/alongside SIP. (Today the web client only has a Screen Wake Lock — no true push.)

**SemVer & compatibility (FR-SDK-10):** the SDK is versioned SemVer; the `/api/session` and `/api/events`
contracts are versioned independently and back-compatible within a major. A changelog ships per release.

---

## 6. Prebuilt UI (FR-SDK-03 / FR-SDK-07)

`InCallUI` — drop-in call & chat screens, built on `InCallClient`:

- Theme via a token set (colors, typography, shapes); light/dark.
- **Arabic + full RTL** out of the box (FR-SDK-07) — the reference UI already ships this.
- Honours tenant **feature flags** (hides chat/location/call controls when disabled) — already enforced
  in the reference client.
- Call-action screens (incoming/outgoing/in-call/hold), chat thread, call history, diagnostics panel.

Integrators can use `InCallUI` wholesale, embed individual screens, or ignore it and build on the
headless `InCallClient`.

---

## 7. Errors, threading, footprint

- **Error model:** `InCallError` with a stable `code` enum (`.notRegistered, .micPermission,
  .peerUnreachable, .busy, .tokenExpired, .featureDisabled, .network, .mediaFailed`) + message. Recoverable
  cases documented per call.
- **Permissions:** the SDK requests mic (and, for location shares, location) and surfaces denials as typed
  errors; it never crashes on a denied permission (a bug the reference already fixed).
- **Threading:** methods callable from the main thread; callbacks delivered on it; heavy work off-thread
  internally.
- **Footprint (FR-SDK-08):** target **≤ 15 MB** added binary and **< 100 ms** cold-start impact — a size
  budget to hold the WebRTC dependency to.

---

## 8. What the SDK talks to (reuse, no new backend to invent)

| SDK action | Platform endpoint (exists today) |
|---|---|
| Fetch brokered identity + creds | `GET /api/session` (Bearer) |
| Emit call/chat/location events → CDR | `POST /api/events` |
| Call history | `GET /api/history` |
| Upload diagnostics | `POST /api/diag` |
| **Register push token** | **new:** `POST /api/push/register` |
| **Receive incoming-call push** | **new:** platform push dispatcher on INVITE |

Only **push** is net-new backend. Everything else the SDK needs already exists and is exercised by the
web client and the smoke tests.

---

## 9. Open questions (close before detailed design)

1. **WebRTC dependency:** bundle libwebrtc directly, or a managed layer (e.g. a thin SIP/WebRTC lib)?
   Drives footprint (FR-SDK-08) and maintenance.
2. **Token refresh contract:** exact `tokenProvider` semantics and the session-token TTL vs SIP-registration
   lifetime.
3. **Push infra:** APNs VoIP + FCM credentials per tenant vs platform-wide; the token-registry data model.
4. **Presence depth:** how much presence (online/offline/in-call) the first SDK version exposes.
5. **RN/Flutter wrappers (FR-SDK-02):** thin bindings over the native SDKs — in Phase 2 or deferred to
   Phase 5?
6. **Distribution:** Swift Package Manager / CocoaPods; Maven/Gradle — and the developer portal + sample
   apps + sandbox (FR-SDK-11).

---

## 10. Summary

The native SDKs are a **port of the reference engine behind this stable API**, talking to the **existing
platform**. The genuinely new engineering is **push + CallKit/ConnectionService** (FR-CALL-02/03,
FR-SDK-06) — the lock-screen, killed-state ringing that makes it a real product — plus packaging,
versioning, and the developer portal. This contract lets the mobile and platform teams build in parallel
against a fixed interface.
