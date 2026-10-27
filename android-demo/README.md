# Callio Android demo

A small native app that shows the Callio Android SDK end to end: sign in, see your contacts and who is online,
call, chat and share your location. It uses the SDK's ready-made call and chat screens (`incall-ui`).

## Run it

1. Open this repo in Android Studio and run the **demo** configuration on a phone or emulator. Or install the
   APK from the latest CI run (Actions → CI → artifact `callio-demo-apk`).
2. Sign in with a user from your Callio organisation or a developer sandbox:
   - **Server:** your Callio platform address. `http://10.0.2.2:8080` reaches a platform on your computer from
     the Android emulator.
   - **Organisation, username, password:** a sandbox gives you two users; sign one in here and the other in a
     second device or the web app, then call between them.

## How it signs in

The demo uses the platform's test sign-in (`POST /api/login`) so it works on its own. A real app never sends
passwords to Callio: your server signs the user in, calls `POST /api/v1/tokens` with your API key, and the app's
`tokenProvider` asks your server for that token.

## What to look at

| File | Shows |
|---|---|
| `DemoViewModel.kt` | Creating `InCallClient`, `start()`, listeners, `dial()`, incoming calls, presence |
| `MainActivity.kt` | Permissions, and the ready-made `CallScreen` and `ChatScreen` |
| `DemoLogin.kt` | Getting a token, and the last known location for sharing |

Ringing while the app is closed needs push (Firebase) and Android's Telecom integration: see
[EXAMPLES.md](../EXAMPLES.md).
