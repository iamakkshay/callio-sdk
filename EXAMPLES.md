# Host-app setup: native ringing, even from a killed app

The native call experience (FR-CALL-02/03/04) is part of the SDKs. A host app only:
- turns on the platform capabilities;
- creates the bridge once;
- on Android, forwards FCM messages.

The Callio platform sends the wake-up push.

```
 Caller dials ─► platform ──(call.ringing)──► push (APNs VoIP / FCM data)
                                                │
   iOS:     PushKit ─► InCallCallKit reports to CallKit ─► system call UI ─► answer ─► SDK registers, media connects
   Android: FCM ─► InCallTelecom.reportIncoming ─► ConnectionService ─► full-screen call notification ─► answer
```

## iOS: [`ios/Examples/CallKitHost.swift`](ios/Examples/CallKitHost.swift)

- Capabilities: **Push Notifications** and **Background Modes → Voice over IP**. Add `NSMicrophoneUsageDescription`.
- At launch:
  ```swift
  let callKit = InCallCallKit(client: client, options: .init(iconTemplateImageData: logoPNG))
  callKit.registerForVoIPPushes()
  ```
- To place calls through CallKit, so they appear in Recents and on the lock screen: `try await callKit.startCall(to: contact)`.
- Audio: `client.audio.available`, `try client.audio.set(.speaker)`, and the delegate method
  `client(_:audioRouteDidChange:)`.
- The bridge follows the client with `addObserver`, so your `delegate` keeps working.
- iOS terminates apps that don't report every VoIP push to CallKit. The bridge always reports: bad pushes and
  pushes that arrive during a call are ended at once, and a push whose call never arrives is ended after 30 s.

## Android: [`android/examples/IncallTelecom.kt`](android/examples/IncallTelecom.kt)

- The library manifest brings the ConnectionService, the notification receiver and the permissions.
- At runtime, ask for `RECORD_AUDIO`, `POST_NOTIFICATIONS` (13+) and `BLUETOOTH_CONNECT` (12+).
- In `Application.onCreate`, call `InCallTelecom.install(this, client)`. Set `InCallTelecom.smallIcon` to your
  notification icon.
- Forward pushes in your `FirebaseMessagingService`:
  `InCallTelecom.reportIncoming(context, PushService.parse(data)!!)`.
- For outgoing calls, `InCallTelecom.startCall(context, contact)`.
- Audio: `client.audio.available`, `client.audio.set(AudioRoute.SPEAKER)`, and
  `InCallListener.onAudioRouteChanged`.

## Still needs a device

All of this compiles against the platform APIs; iOS is typechecked against the iOS frameworks. Ringing from a
killed app, Bluetooth hand-off and car kits still need a run on physical phones, with real APNs and FCM
credentials.
