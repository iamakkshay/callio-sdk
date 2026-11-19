## 0.3.1

- Uses Callio Android and iOS SDKs 0.3.1: messages to someone who is offline are delivered when they're back
  (`MessageStatus.queued`), and keypad tones work on Android.

## 0.3.0

- Uses Callio Android and iOS SDKs 0.3.0. Flutter is now a full platform SDK: the plugin runs on the native SDKs, with ready-made call and chat screens.
- Connections must use https/wss; set `allowInsecureTransport` only for local development.
- Tokens can be bound to one device.
- `CallStateChanged.reason` says why a call ended (declined, missed, no-answer, busy, unreachable).

## 0.2.3

- Uses Callio Android and iOS SDKs 0.2.3: hold and resume, 3-way calls, clearer audio, ringing when the app is closed.

## 0.2.2

- Uses Callio Android and iOS SDKs 0.2.2: incoming calls ring and can be answered, chat sends and receives.

## 0.2.1

- Uses Callio Android SDK 0.2.1, which turns on WebRTC calls by default.

## 0.2.0

- First public release: calls, chat, live location and push wake-up, bridged to the native Callio iOS and Android SDKs.
