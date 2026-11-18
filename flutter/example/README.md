# incall_flutter example

Signs in with a token from a configurable backend, shows the registration state, lists the directory with
presence, dials and receives calls with the ready-made screens, chats, and shows call history.

```sh
flutter run                                    # Android emulator, platform at http://10.0.2.2:8080
flutter run --dart-define=CALLIO_BASE_URL=https://callio.example.com \
            --dart-define=CALLIO_TOKEN_URL=https://your-backend.example.com/callio-token
```

Other defaults: `CALLIO_USERNAME`, `CALLIO_PASSWORD`, `CALLIO_TENANT`. See the plugin README for setup details.
