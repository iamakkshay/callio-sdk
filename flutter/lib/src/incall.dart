import 'package:flutter/services.dart';

import 'models.dart';

/// Flutter entry point for the In-Call SDK. Thin wrapper over the native iOS/Android SDKs via platform
/// channels — the Dart API mirrors docs/SDK_API_CONTRACT.md. One instance per signed-in user.
///
/// Registration and chat work today; placing a call needs the native WebRTC media layer linked on the
/// device (see sdk/README.md).
class InCall {
  InCall._();
  static final InCall instance = InCall._();

  static const MethodChannel _channel = MethodChannel('incall_flutter');
  static const EventChannel _eventChannel = EventChannel('incall_flutter/events');

  Future<String> Function()? _tokenProvider;
  Stream<InCallEvent>? _events;

  /// A broadcast stream of SDK events (registration, incoming calls, call state, messages, quality).
  Stream<InCallEvent> get events =>
      _events ??= _eventChannel.receiveBroadcastStream().map(InCallEvent.fromMap).asBroadcastStream();

  /// Fetch the brokered session and register. The SDK never logs in — [tokenProvider] returns a
  /// short-lived tenant JWT minted by your backend; the native side calls it on demand.
  Future<void> start({
    required String baseUrl,
    required Future<String> Function() tokenProvider,
    bool forceRelay = false,
  }) async {
    _tokenProvider = tokenProvider;
    _channel.setMethodCallHandler(_onNativeCall);
    await _channel.invokeMethod('start', {'baseUrl': baseUrl, 'forceRelay': forceRelay});
  }

  Future<void> stop() => _channel.invokeMethod('stop');

  // ---- calls ----

  /// Place a call; returns the active [Call]. Honours the tenant's calling feature flag.
  Future<Call> dial(String sipUser) async {
    final id = await _channel.invokeMethod<String>('dial', {'sipUser': sipUser});
    return Call(id ?? '', sipUser);
  }

  Future<void> answer() => _channel.invokeMethod('answer');
  Future<void> decline() => _channel.invokeMethod('decline');
  Future<void> hangup() => _channel.invokeMethod('hangup');
  Future<void> setMuted(bool muted) => _channel.invokeMethod('setMuted', {'muted': muted});
  Future<void> setHold(bool held) => _channel.invokeMethod('setHold', {'held': held});
  Future<void> sendDtmf(String tone) => _channel.invokeMethod('sendDtmf', {'tone': tone});

  /// Route call audio: 'earpiece', 'speaker' or 'bluetooth' (FR-CALL-04). Changes arrive as [AudioRouteChanged].
  Future<void> setAudioRoute(String route) {
    if (!const ['earpiece', 'speaker', 'bluetooth'].contains(route)) throw ArgumentError.value(route, 'route');
    return _channel.invokeMethod('setAudioRoute', {'route': route});
  }

  // ---- chat / location ----

  Future<String> sendText(String toSipUser, String text) async =>
      await _channel.invokeMethod<String>('sendMessage', {'to': toSipUser, 'text': text}) ?? '';

  Future<String> sendLocation(String toSipUser, SharedLocation location) async =>
      await _channel.invokeMethod<String>('sendMessage', {
        'to': toSipUser,
        'location': {'lat': location.lat, 'lng': location.lng, 'label': location.label},
      }) ??
      '';

  Future<void> setTyping(String toSipUser, bool typing) =>
      _channel.invokeMethod('setTyping', {'to': toSipUser, 'typing': typing});

  // ---- history / push ----

  Future<List<HistoryEntry>> callHistory({int limit = 50}) async {
    final raw = await _channel.invokeMethod<List>('callHistory', {'limit': limit}) ?? const [];
    return raw.map((e) => HistoryEntry.fromMap(Map.from(e as Map))).toList();
  }

  /// Register this device's push token (APNs VoIP on iOS, FCM on Android) for killed-state ringing.
  Future<void> registerPush(String token) => _channel.invokeMethod('registerPush', {'token': token});

  // The native side asks Dart for a fresh token when it needs one.
  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method == 'getToken') return await _tokenProvider?.call();
    return null;
  }
}

/// A single call. Methods delegate to the SDK; observe lifecycle via [InCall.events].
class Call {
  final String id;
  final String peerSipUser;
  const Call(this.id, this.peerSipUser);

  Future<void> answer() => InCall.instance.answer();
  Future<void> hangup() => InCall.instance.hangup();
  Future<void> decline() => InCall.instance.decline();
  Future<void> setMuted(bool muted) => InCall.instance.setMuted(muted);
  Future<void> setHold(bool held) => InCall.instance.setHold(held);
  Future<void> sendDtmf(String tone) => InCall.instance.sendDtmf(tone);
}
