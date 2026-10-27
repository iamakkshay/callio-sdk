import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:incall_flutter/incall_flutter.dart';

// Point these at your running platform-api + a lab account.
const _baseUrl = 'http://10.0.2.2:8080'; // Android emulator -> host; use your LAN IP on a device
const _username = 'akshay';
const _password = 'akshay123';
const _peerSipUser = '1005'; // vineet

void main() => runApp(const MaterialApp(home: DemoScreen()));

class DemoScreen extends StatefulWidget {
  const DemoScreen({super.key});
  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  final _incall = InCall.instance;
  RegistrationState _reg = RegistrationState.offline;
  String _status = 'idle';
  final _log = <String>[];

  @override
  void initState() {
    super.initState();
    _incall.events.listen(_onEvent);
    _connect();
  }

  // The tenant backend mints the token; here the dev /api/login stands in.
  Future<String> _fetchToken() async {
    final req = await HttpClient().postUrl(Uri.parse('$_baseUrl/api/login'));
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode({'username': _username, 'password': _password})));
    final resp = await req.close();
    final body = jsonDecode(await resp.transform(utf8.decoder).join());
    return body['token'] as String;
  }

  Future<void> _connect() async {
    try {
      await _incall.start(baseUrl: _baseUrl, tokenProvider: _fetchToken);
    } catch (e) {
      setState(() => _status = 'start failed: $e');
    }
  }

  void _onEvent(InCallEvent e) {
    setState(() {
      switch (e) {
        case RegistrationChanged(:final state):
          _reg = state;
        case IncomingCall(:final from):
          _status = 'incoming from ${from?.displayName ?? 'peer'}';
          _log.insert(0, 'incoming call');
        case CallStateChanged(:final state):
          _status = 'call: $state';
        case QualityUpdated(:final quality):
          _status = 'connected · ${quality.rttMs ?? '-'} ms';
        case MessageReceived(:final message):
          _log.insert(0, 'msg: ${message.text ?? '[location]'}');
        case AudioRouteChanged(:final route):
          _log.insert(0, 'audio: $route');
        case CallFailed(:final message):
          _log.insert(0, 'error: $message');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('In-Call · ${_reg.name}')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_status, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: () => _incall.dial(_peerSipUser), child: const Text('Call')),
            OutlinedButton(onPressed: () => _incall.answer(), child: const Text('Answer')),
            OutlinedButton(onPressed: () => _incall.hangup(), child: const Text('Hang up')),
            OutlinedButton(onPressed: () => _incall.sendText(_peerSipUser, 'Hi from Flutter'), child: const Text('Chat')),
          ]),
          const SizedBox(height: 16),
          const Text('Events', style: TextStyle(fontWeight: FontWeight.bold)),
          Expanded(child: ListView(children: _log.map((l) => Text(l)).toList())),
        ]),
      ),
    );
  }
}
