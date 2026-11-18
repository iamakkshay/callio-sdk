import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:incall_flutter/incall_ui.dart';

import 'main.dart';
import 'token_client.dart';

/// Where to sign in: the Callio platform URL, and the backend URL that hands out tokens.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.onSignedIn});
  final VoidCallback onSignedIn;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _form = GlobalKey<FormState>();
  final _baseUrl = TextEditingController(text: defaultBaseUrl);
  final _tokenUrl = TextEditingController(text: defaultTokenUrl);
  final _username = TextEditingController(text: defaultUsername);
  final _password = TextEditingController(text: defaultPassword);
  final _tenant = TextEditingController(text: defaultTenant);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_baseUrl, _tokenUrl, _username, _password, _tenant]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _effectiveTokenUrl {
    final t = _tokenUrl.text.trim();
    if (t.isNotEmpty) return t;
    final base = _baseUrl.text.trim().replaceAll(RegExp(r'/+$'), '');
    return '$base/api/login';
  }

  String? _url(String? v) => (v ?? '').trim().isEmpty || RegExp(r'^https?://').hasMatch(v!.trim()) ? null : 'Use an http(s) URL';

  Future<void> _signIn() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final tokens = TokenClient(
      tokenUrl: _effectiveTokenUrl,
      username: _username.text.trim(),
      password: _password.text,
      tenant: _tenant.text.trim(),
    );
    try {
      await tokens.fetch(); // fail fast with a clear message if the backend is wrong
      await InCall.instance.requestPermissions();
      // A lab platform on plain http/ws is allowed in debug builds only; release builds require https/wss.
      await InCall.instance.start(
          baseUrl: _baseUrl.text.trim(), tokenProvider: tokens.fetch, allowInsecureTransport: kDebugMode);
      widget.onSignedIn();
    } on TokenException catch (e) {
      setState(() => _error = 'Token backend: $e');
    } on InCallException catch (e) {
      setState(() => _error = 'Callio: ${e.message} (${e.code.name})');
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _form,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Icon(Icons.call_outlined, size: 40, color: scheme.primary),
                  const SizedBox(height: 12),
                  Text('Callio example', style: text.headlineSmall, textAlign: TextAlign.center),
                  const SizedBox(height: 6),
                  Text('Sign in with a token from your backend.',
                      style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant), textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _baseUrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(labelText: 'Callio platform URL'),
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : _url(v),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _tokenUrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Token backend URL',
                      helperText: 'Empty: <platform>/api/login (lab installs only)',
                    ),
                    validator: _url,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _username,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Username'),
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
                  const SizedBox(height: 12),
                  TextFormField(controller: _tenant, autocorrect: false, decoration: const InputDecoration(labelText: 'Tenant (optional)')),
                  const SizedBox(height: 20),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!, style: TextStyle(color: scheme.error)),
                    ),
                  FilledButton(
                    onPressed: _busy ? null : _signIn,
                    child: _busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Sign in'),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
