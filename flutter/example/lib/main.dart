import 'package:flutter/material.dart';
import 'package:incall_flutter/incall_ui.dart';

import 'home.dart';
import 'sign_in.dart';

// Defaults for the sign-in form. Override at build time, for example:
//   flutter run --dart-define=CALLIO_BASE_URL=https://callio.example.com \
//               --dart-define=CALLIO_TOKEN_URL=https://backend.example.com/callio-token
const defaultBaseUrl = String.fromEnvironment('CALLIO_BASE_URL', defaultValue: 'http://10.0.2.2:8080'); // emulator -> host
const defaultTokenUrl = String.fromEnvironment('CALLIO_TOKEN_URL'); // empty: <base URL>/api/login (lab only)
const defaultUsername = String.fromEnvironment('CALLIO_USERNAME');
const defaultPassword = String.fromEnvironment('CALLIO_PASSWORD');
const defaultTenant = String.fromEnvironment('CALLIO_TENANT');

void main() => runApp(const CallioExampleApp());

class CallioExampleApp extends StatefulWidget {
  const CallioExampleApp({super.key});

  @override
  State<CallioExampleApp> createState() => _CallioExampleAppState();
}

class _CallioExampleAppState extends State<CallioExampleApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  bool _signedIn = false;

  void _openChat(BuildContext context, CallController call) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ChatScreen(peerSipUser: call.peerSipUser, title: call.displayName),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Callio example',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: CallioTheme.light(),
      darkTheme: CallioTheme.dark(),
      // Rings show the ready-made incoming-call screen wherever the user is in the app.
      builder: (context, child) => CallioCallListener(navigatorKey: _navigatorKey, onChat: _openChat, child: child!),
      home: _signedIn
          ? HomeScreen(onSignedOut: () => setState(() => _signedIn = false), onChat: _openChat)
          : SignInScreen(onSignedIn: () => setState(() => _signedIn = true)),
    );
  }
}
