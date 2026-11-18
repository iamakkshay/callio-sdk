import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// Flutter entry point for the Callio SDK: a thin layer over the native iOS (`InCallSDK`) and Android
/// (`com.ngx.incall`) SDKs via platform channels. The API mirrors docs/SDK_API_CONTRACT.md.
/// One instance per signed-in user: [InCall.instance].
///
/// Methods throw [InCallException] with a stable [InCallErrorCode] when the native side fails.
class InCall {
  InCall._();
  static final InCall instance = InCall._();

  static const MethodChannel _channel = MethodChannel('incall_flutter');
  static const EventChannel _eventChannel = EventChannel('incall_flutter/events');

  Future<String> Function()? _tokenProvider;
  Stream<InCallEvent>? _events;
  StreamSubscription<InCallEvent>? _tracker;

  RegistrationState _registrationState = RegistrationState.offline;
  Call? _currentCall;
  final _registration = StreamController<RegistrationState>.broadcast();

  /// A broadcast stream of SDK events (registration, incoming calls, call state, messages, quality, ...).
  Stream<InCallEvent> get events =>
      _events ??= _eventChannel.receiveBroadcastStream().map(InCallEvent.fromMap).asBroadcastStream();

  /// The last registration state reported by the native SDK.
  RegistrationState get registrationState => _registrationState;

  /// Registration changes only (convenience over [events]).
  Stream<RegistrationState> get registrationChanges => _registration.stream;

  /// The call in progress (ringing, dialling, connected or on hold), or null.
  Call? get currentCall => _currentCall;

  void _track() {
    _tracker ??= events.listen(_onEvent, onError: (Object _) {});
  }

  void _onEvent(InCallEvent e) {
    switch (e) {
      case RegistrationChanged(:final state):
        _registrationState = state;
        _registration.add(state);
      case IncomingCall(:final callId, :final from):
        _currentCall = Call(callId, from?.sipUser ?? '', direction: CallDirection.incoming, peer: from);
      case CallStateChanged(:final callId, :final status, :final peer, :final direction):
        if (status == CallStatus.ended) {
          if (_currentCall?.id == callId) _currentCall = null;
        } else if (_currentCall?.id != callId && callId.isNotEmpty) {
          _currentCall = Call(callId, peer?.sipUser ?? '', direction: direction ?? CallDirection.outgoing, peer: peer);
        }
      case ConferenceStarted(:final callId, :final room):
        _currentCall = Call(callId, room, direction: CallDirection.outgoing);
      default:
        break;
    }
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw InCallException(errorCodeFromWire(e.code), e.message ?? e.code, rawCode: e.code);
    } on MissingPluginException {
      throw const InCallException(InCallErrorCode.unknown,
          'incall_flutter is not linked on this platform (run on Android or iOS, after a full rebuild)',
          rawCode: 'missingPlugin');
    }
  }

  /// Fetch the brokered session and register. The SDK never logs in: [tokenProvider] returns a
  /// short-lived tenant token minted by your backend; the native side calls it on start and whenever
  /// the token expires.
  ///
  /// [nativeCallUi] hands calls to the system call UI as well: CallKit and PushKit VoIP pushes on iOS,
  /// a self-managed ConnectionService with a full-screen incoming-call notification on Android.
  /// [disconnectInBackground] closes the signalling socket while the app is in the background with no
  /// call; incoming calls then arrive by push (NFR-13).
  ///
  /// [allowInsecureTransport] is for DEVELOPMENT only: it allows an `http://` [baseUrl] and `ws://` signalling
  /// (a local stack or lab server). Without it the SDK requires `https://` and `wss://`. Never set it in a
  /// release build (e.g. pass `kDebugMode`).
  Future<void> start({
    required String baseUrl,
    required Future<String> Function() tokenProvider,
    bool forceRelay = false,
    bool disconnectInBackground = true,
    bool nativeCallUi = true,
    bool allowInsecureTransport = false,
  }) async {
    if (RegExp(r'^http://.', caseSensitive: false).hasMatch(baseUrl)) {
      if (!allowInsecureTransport) {
        throw ArgumentError.value(baseUrl, 'baseUrl',
            'must use https:// (http:// is allowed only with allowInsecureTransport: true, for development)');
      }
    } else if (!RegExp(r'^https://.', caseSensitive: false).hasMatch(baseUrl)) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'must be an https:// URL');
    }
    _tokenProvider = tokenProvider;
    _channel.setMethodCallHandler(_onNativeCall);
    _track();
    await _invoke<void>('start', {
      'baseUrl': baseUrl,
      'forceRelay': forceRelay,
      'disconnectInBackground': disconnectInBackground,
      'nativeCallUi': nativeCallUi,
      'allowInsecureTransport': allowInsecureTransport,
    });
  }

  /// Unregister and tear down the session.
  Future<void> stop() async {
    await _invoke<void>('stop');
    _currentCall = null;
  }

  /// The signed-in user's session (features, directory, user type), or null before [start] completes.
  Future<InCallSession?> session() async {
    final m = await _invoke<Map>('session');
    return m == null ? null : InCallSession.fromMap(m);
  }

  /// Ask for the microphone (and, on Android 13+, notifications for incoming calls). Returns what was granted.
  Future<Map<String, bool>> requestPermissions() async {
    final m = await _invoke<Map>('requestPermissions') ?? const {};
    return m.map((k, v) => MapEntry('$k', v == true));
  }

  /// The native SDK version (FR-SDK-10).
  Future<String> nativeSdkVersion() async => await _invoke<String>('sdkVersion') ?? '';

  // ---- calls ----

  /// Place a call to a SIP extension (or directory username). Honours the tenant's calling flag.
  Future<Call> dial(String sipUser) async {
    if (sipUser.trim().isEmpty) throw ArgumentError.value(sipUser, 'sipUser', 'must not be empty');
    final id = await _invoke<String>('dial', {'sipUser': sipUser});
    final call = Call(id ?? '', sipUser, direction: CallDirection.outgoing);
    _currentCall = call;
    return call;
  }

  Future<void> answer() => _invoke<void>('answer');
  Future<void> decline() => _invoke<void>('decline');

  /// Cancel an outgoing call before it is answered.
  Future<void> cancel() => _invoke<void>('cancel');
  Future<void> hangup() => _invoke<void>('hangup');
  Future<void> setMuted(bool muted) => _invoke<void>('setMuted', {'muted': muted});
  Future<void> setHold(bool held) => _invoke<void>('setHold', {'held': held});

  /// Send one DTMF tone: 0-9, *, #, A-D.
  Future<void> sendDtmf(String tone) {
    if (!RegExp(r'^[0-9*#A-D]$').hasMatch(tone)) throw ArgumentError.value(tone, 'tone', 'must be one of 0-9 * # A-D');
    return _invoke<void>('sendDtmf', {'tone': tone});
  }

  /// Route call audio: 'earpiece', 'speaker' or 'bluetooth' (FR-CALL-04). Changes arrive as [AudioRouteChanged].
  Future<void> setAudioRoute(String route) {
    if (!const ['earpiece', 'speaker', 'bluetooth'].contains(route)) throw ArgumentError.value(route, 'route');
    return _invoke<void>('setAudioRoute', {'route': route});
  }

  /// Which audio outputs exist right now, and which is in use.
  Future<AudioRoutes> audioRoutes() async =>
      AudioRoutes.fromMap(await _invoke<Map>('audioRoutes') ?? const {'available': ['earpiece', 'speaker'], 'current': 'earpiece'});

  /// Transfer the current call to another extension (blind REFER).
  Future<void> transfer(String sipUser) => _invoke<void>('transfer', {'sipUser': sipUser});

  /// Join a 3-way call you were invited to ([ConferenceInviteReceived]). Ends the current call first.
  Future<Call> joinConference(String room) async {
    final id = await _invoke<String>('joinConference', {'room': room});
    final call = Call(id ?? '', room, direction: CallDirection.outgoing);
    _currentCall = call;
    return call;
  }

  // ---- chat / location ----

  Future<String> sendText(String toSipUser, String text) async =>
      await _invoke<String>('sendMessage', {'to': toSipUser, 'text': text}) ?? '';

  Future<String> sendLocation(String toSipUser, SharedLocation location) async {
    if (!(location.lat.abs() <= 90 && location.lng.abs() <= 180)) throw ArgumentError('invalid coordinates');
    return await _invoke<String>('sendMessage', {
          'to': toSipUser,
          'location': {'lat': location.lat, 'lng': location.lng, 'label': location.label},
        }) ??
        '';
  }

  Future<void> setTyping(String toSipUser, bool typing) => _invoke<void>('setTyping', {'to': toSipUser, 'typing': typing});

  /// Messages exchanged with [peerSipUser] since [start] (the native SDK keeps them in memory).
  Future<List<Message>> messages(String peerSipUser) async {
    final raw = await _invoke<List>('messages', {'peer': peerSipUser}) ?? const [];
    return raw.whereType<Map>().map(Message.fromMap).toList();
  }

  // ---- presence ----

  /// Ask once who is online (default: the directory). Returns sipUser to connected.
  Future<Map<String, bool>> refreshPresence([List<String>? sipUsers]) async {
    final m = await _invoke<Map>('refreshPresence', {'sipUsers': sipUsers}) ?? const {};
    return m.map((k, v) => MapEntry('$k', v == true));
  }

  /// Poll presence every [every]; changes arrive as [PresenceChanged].
  Future<void> startPresenceUpdates({Duration every = const Duration(seconds: 30)}) =>
      _invoke<void>('startPresenceUpdates', {'everyMs': every.inMilliseconds});
  Future<void> stopPresenceUpdates() => _invoke<void>('stopPresenceUpdates');

  // ---- history / push ----

  Future<List<HistoryEntry>> callHistory({int limit = 50}) async {
    final raw = await _invoke<List>('callHistory', {'limit': limit}) ?? const [];
    return raw.whereType<Map>().map(HistoryEntry.fromMap).toList();
  }

  /// Register this device's push token for killed-state ringing: the FCM token on Android. On iOS the
  /// VoIP token is registered automatically when [start] runs with `nativeCallUi: true`; passing an APNs
  /// VoIP token here also works.
  Future<void> registerPush(String token) => _invoke<void>('registerPush', {'token': token});
  Future<void> unregisterPush() => _invoke<void>('unregisterPush');

  /// Android: hand an FCM data message (`RemoteMessage.data`) to the SDK. If it is an incoming-call push
  /// it rings through the system call UI and returns true. iOS VoIP pushes go through PushKit natively,
  /// so this returns false there.
  Future<bool> handlePush(Map<String, String> data) async => await _invoke<bool>('handlePush', {'data': data}) ?? false;

  // The native side asks Dart for a fresh token when it needs one.
  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method == 'getToken') {
      final p = _tokenProvider;
      if (p == null) return null;
      try {
        return await p();
      } catch (_) {
        return null; // native reports tokenExpired
      }
    }
    return null;
  }

  /// Drop cached state and listeners between tests.
  @visibleForTesting
  void debugReset() {
    _tracker?.cancel();
    _tracker = null;
    _events = null;
    _tokenProvider = null;
    _registrationState = RegistrationState.offline;
    _currentCall = null;
  }

  /// Feed an event through the tracker, as if native had sent it (tests).
  @visibleForTesting
  void debugHandleEvent(InCallEvent e) => _onEvent(e);
}

/// A single call. Methods delegate to the SDK; observe its lifecycle via [InCall.events] or a CallController.
class Call {
  final String id;
  final String peerSipUser;
  final CallDirection direction;

  /// The other party, when the SDK knows it (incoming calls, directory contacts).
  final Contact? peer;
  const Call(this.id, this.peerSipUser, {this.direction = CallDirection.outgoing, this.peer});

  Future<void> answer() => InCall.instance.answer();
  Future<void> hangup() => InCall.instance.hangup();
  Future<void> decline() => InCall.instance.decline();
  Future<void> cancel() => InCall.instance.cancel();
  Future<void> setMuted(bool muted) => InCall.instance.setMuted(muted);
  Future<void> setHold(bool held) => InCall.instance.setHold(held);
  Future<void> sendDtmf(String tone) => InCall.instance.sendDtmf(tone);
  Future<void> setAudioRoute(String route) => InCall.instance.setAudioRoute(route);
  Future<void> transfer(String sipUser) => InCall.instance.transfer(sipUser);
}
