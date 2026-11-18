import 'dart:convert';
import 'dart:io';

/// Gets a Callio token from your backend. The SDK never logs anyone in: your server authenticates the user
/// and mints a short-lived token (on the Callio platform: `POST /api/v1/tokens` with your tenant API key).
///
/// This demo POSTs `{"username", "password", "tenant"}` as JSON to [tokenUrl] and reads `token` from the
/// JSON reply. The platform's development endpoint `/api/login` answers exactly that way, so pointing
/// [tokenUrl] at `<platform>/api/login` works against a lab install. Point it at your own backend in a real app.
class TokenClient {
  TokenClient({required this.tokenUrl, required this.username, this.password = '', this.tenant = ''});

  final String tokenUrl, username, password, tenant;

  Future<String> fetch() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(Uri.parse(tokenUrl));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'username': username,
        if (password.isNotEmpty) 'password': password,
        if (tenant.isNotEmpty) 'tenant': tenant,
      }));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final text = await resp.transform(utf8.decoder).join();
      final body = text.isEmpty ? const {} : jsonDecode(text);
      if (resp.statusCode != 200) {
        final msg = body is Map && body['error'] is String ? body['error'] as String : 'HTTP ${resp.statusCode}';
        throw TokenException(msg);
      }
      final token = body is Map ? body['token'] : null;
      if (token is! String || token.isEmpty) throw const TokenException('the reply has no "token"');
      return token;
    } on SocketException catch (e) {
      throw TokenException('cannot reach $tokenUrl (${e.osError?.message ?? e.message})');
    } finally {
      client.close();
    }
  }
}

class TokenException implements Exception {
  const TokenException(this.message);
  final String message;
  @override
  String toString() => message;
}
