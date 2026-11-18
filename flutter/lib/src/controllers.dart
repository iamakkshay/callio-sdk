import 'dart:async';

import 'package:flutter/foundation.dart';

import 'incall.dart';
import 'models.dart';

/// Live state of one call (status, mute, hold, audio route, quality, duration) built from [InCall.events],
/// with the call controls. A [ChangeNotifier], so it drives a custom call UI as well as the ready-made
/// InCallScreen. Dispose it when the call screen goes away.
class CallController extends ChangeNotifier {
  CallController({
    InCall? incall,
    String? callId,
    String peerSipUser = '',
    Contact? peer,
    this.direction = CallDirection.outgoing,
    CallStatus status = CallStatus.initiating,
  })  : _incall = incall ?? InCall.instance,
        _callId = callId ?? '',
        _peerSipUser = peer?.sipUser ?? peerSipUser,
        _peer = peer,
        _status = status {
    _sub = _incall.events.listen(_onEvent, onError: (Object _) {});
    _loadRoutes();
  }

  /// A controller for a call returned by [InCall.dial] or tracked as [InCall.currentCall].
  factory CallController.forCall(Call call, {InCall? incall}) => CallController(
        incall: incall,
        callId: call.id,
        peerSipUser: call.peerSipUser,
        peer: call.peer,
        direction: call.direction,
        status: call.direction == CallDirection.incoming ? CallStatus.ringing : CallStatus.initiating,
      );

  /// A controller for a ringing incoming call.
  factory CallController.incoming(IncomingCall e, {InCall? incall}) => CallController(
        incall: incall,
        callId: e.callId,
        peer: e.from,
        peerSipUser: e.from?.sipUser ?? '',
        direction: CallDirection.incoming,
        status: CallStatus.ringing,
      );

  final InCall _incall;
  late final StreamSubscription<InCallEvent> _sub;
  final CallDirection direction;

  String _callId;
  String _peerSipUser;
  Contact? _peer;
  CallStatus _status;
  String? _endReason;
  bool _muted = false, _held = false, _disposed = false;
  AudioRoute _route = AudioRoute.earpiece;
  List<AudioRoute> _routes = const [AudioRoute.earpiece, AudioRoute.speaker];
  CallQuality? _quality;
  DateTime? _connectedAt;
  Object? _lastError;

  String get callId => _callId;
  String get peerSipUser => _peerSipUser;
  Contact? get peer => _peer;

  /// The name to show: the contact's display name, else the extension.
  String get displayName => (_peer?.displayName.isNotEmpty ?? false) ? _peer!.displayName : _peerSipUser;
  CallStatus get status => _status;

  /// Why the call ended (ended, declined, missed, no-answer, busy, unreachable), once [status] is ended.
  String? get endReason => _endReason;
  bool get isMuted => _muted;
  bool get isOnHold => _held;
  bool get isEnded => _status == CallStatus.ended;
  bool get isRinging => _status == CallStatus.ringing && direction == CallDirection.incoming;
  bool get isConnected => _status == CallStatus.connected || _status == CallStatus.onHold || _status == CallStatus.reconnecting;
  AudioRoute get audioRoute => _route;
  List<AudioRoute> get availableRoutes => _routes;
  CallQuality? get quality => _quality;
  DateTime? get connectedAt => _connectedAt;

  /// The last error a control raised (also rethrown to the caller).
  Object? get lastError => _lastError;

  /// Time since the call connected (zero before).
  Duration get elapsed => _connectedAt == null ? Duration.zero : DateTime.now().difference(_connectedAt!);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _isMine(String id) {
    if (id.isEmpty) return false;
    if (_callId.isEmpty) {
      _callId = id; // adopt the first call we hear about (dial returned before the id was known)
      return true;
    }
    return id == _callId;
  }

  void _onEvent(InCallEvent e) {
    switch (e) {
      case CallStateChanged(:final callId, :final status, :final reason, :final peer, :final muted, :final held):
        if (!_isMine(callId) || _status == CallStatus.ended) return;
        _status = status;
        if (peer != null && (_peer == null || _peer!.displayName == _peer!.sipUser)) {
          _peer = peer;
          if (_peerSipUser.isEmpty) _peerSipUser = peer.sipUser;
        }
        if (muted != null) _muted = muted;
        if (held != null) _held = held;
        if (status == CallStatus.onHold) _held = true;
        if (status == CallStatus.connected) {
          _held = false;
          _connectedAt ??= DateTime.now();
          _loadRoutes();
        }
        if (status == CallStatus.ended) _endReason = reason ?? 'ended';
        _notify();
      case QualityUpdated(:final quality, :final callId):
        if (callId != null && callId.isNotEmpty && !_isMine(callId)) return;
        if (isEnded) return;
        _quality = quality;
        _notify();
      case AudioRouteChanged(:final audioRoute):
        if (isEnded) return;
        _route = audioRoute;
        if (!_routes.contains(audioRoute)) _routes = [..._routes, audioRoute];
        _notify();
      default:
        break;
    }
  }

  Future<void> _loadRoutes() async {
    try {
      final r = await _incall.audioRoutes();
      if (r.available.isNotEmpty) _routes = r.available;
      _route = r.current;
      _notify();
    } catch (_) {
      // Not registered yet or no audio device info: keep the defaults.
    }
  }

  Future<void> _guard(Future<void> Function() action, void Function() undo) async {
    try {
      await action();
    } catch (e) {
      _lastError = e;
      undo();
      _notify();
      rethrow;
    }
  }

  Future<void> answer() => _incall.answer();
  Future<void> decline() => _incall.decline();

  /// End the call the right way for its state: decline a ringing incoming call, cancel an unanswered
  /// outgoing one, otherwise hang up.
  Future<void> end() {
    if (isEnded) return Future.value();
    if (isRinging) return _incall.decline();
    if (direction == CallDirection.outgoing && (_status == CallStatus.initiating || _status == CallStatus.ringing)) {
      return _incall.cancel();
    }
    return _incall.hangup();
  }

  Future<void> setMuted(bool muted) {
    final before = _muted;
    _muted = muted;
    _notify();
    return _guard(() => _incall.setMuted(muted), () => _muted = before);
  }

  Future<void> toggleMute() => setMuted(!_muted);

  Future<void> setHold(bool held) {
    final before = _held;
    _held = held;
    _notify();
    return _guard(() => _incall.setHold(held), () => _held = before);
  }

  Future<void> toggleHold() => setHold(!_held);

  Future<void> setAudioRoute(AudioRoute route) {
    final before = _route;
    _route = route;
    _notify();
    return _guard(() => _incall.setAudioRoute(route.name), () => _route = before);
  }

  /// Speaker on or off (back to the earpiece, or Bluetooth when that is the only other route).
  Future<void> toggleSpeaker() {
    if (_route == AudioRoute.speaker) {
      final back = _routes.contains(AudioRoute.bluetooth) && !_routes.contains(AudioRoute.earpiece) ? AudioRoute.bluetooth : AudioRoute.earpiece;
      return setAudioRoute(back);
    }
    return setAudioRoute(AudioRoute.speaker);
  }

  Future<void> sendDtmf(String tone) => _incall.sendDtmf(tone);

  /// Feed an event directly (tests, or apps that multiplex events themselves).
  @visibleForTesting
  void handleEvent(InCallEvent e) => _onEvent(e);

  @override
  void dispose() {
    _disposed = true;
    _sub.cancel();
    super.dispose();
  }
}

/// One 1:1 conversation: the message list (with delivery status), sending text and locations, and the
/// typing indicator. Built from [InCall.events]; a [ChangeNotifier] for the ready-made ChatView or your own UI.
class ChatController extends ChangeNotifier {
  ChatController({required this.peerSipUser, InCall? incall, this.typingIdle = const Duration(seconds: 3)})
      : _incall = incall ?? InCall.instance {
    _sub = _incall.events.listen(_onEvent, onError: (Object _) {});
  }

  final String peerSipUser;
  final Duration typingIdle;
  final InCall _incall;
  late final StreamSubscription<InCallEvent> _sub;
  final List<Message> _messages = [];
  bool _disposed = false, _typing = false, _loading = false;
  Timer? _typingTimer;
  int _localSeq = 0;

  /// Oldest first.
  List<Message> get messages => List.unmodifiable(_messages);
  bool get isLoading => _loading;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Load what the native SDK already holds for this conversation (messages since [InCall.start]).
  Future<void> load() async {
    _loading = true;
    _notify();
    try {
      final existing = await _incall.messages(peerSipUser);
      for (final m in existing) {
        if (!_messages.any((x) => x.id == m.id)) _messages.add(m);
      }
    } catch (_) {
      // Not started yet: start empty.
    } finally {
      _loading = false;
      _notify();
    }
  }

  void _onEvent(InCallEvent e) {
    switch (e) {
      case MessageReceived(:final message, :final peerSip):
        if (peerSip != peerSipUser || _messages.any((m) => m.id == message.id)) return;
        _messages.add(message);
        _notify();
      case MessageStatusChanged(:final messageId, :final status):
        final i = _messages.indexWhere((m) => m.id == messageId);
        if (i < 0) return;
        _messages[i] = _messages[i].copyWith(status: status.name);
        _notify();
      default:
        break;
    }
  }

  Future<Message> _send(Message pending, Future<String> Function() send) async {
    _messages.add(pending);
    _notify();
    stopTyping();
    try {
      final id = await send();
      final i = _messages.indexWhere((m) => m.id == pending.id);
      final sent = Message(id: id.isEmpty ? pending.id : id, from: MessageSender.me, text: pending.text, location: pending.location, status: 'sending');
      if (i >= 0) _messages[i] = sent;
      _notify();
      return sent;
    } catch (e) {
      final i = _messages.indexWhere((m) => m.id == pending.id);
      if (i >= 0) _messages[i] = pending.copyWith(status: 'failed');
      _notify();
      rethrow;
    }
  }

  Future<Message> sendText(String text) {
    final t = text.trim();
    if (t.isEmpty) throw ArgumentError.value(text, 'text', 'must not be empty');
    return _send(Message(id: 'local-${_localSeq++}', from: MessageSender.me, text: t, status: 'sending'),
        () => _incall.sendText(peerSipUser, t));
  }

  Future<Message> sendLocation(SharedLocation location) =>
      _send(Message(id: 'local-${_localSeq++}', from: MessageSender.me, location: location, status: 'sending'),
          () => _incall.sendLocation(peerSipUser, location));

  /// Call on every keystroke: sends "typing" once, and "stopped" after [typingIdle] without input.
  void typing() {
    if (!_typing) {
      _typing = true;
      _incall.setTyping(peerSipUser, true).catchError((Object _) {});
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(typingIdle, stopTyping);
  }

  void stopTyping() {
    _typingTimer?.cancel();
    _typingTimer = null;
    if (!_typing) return;
    _typing = false;
    _incall.setTyping(peerSipUser, false).catchError((Object _) {});
  }

  @visibleForTesting
  void handleEvent(InCallEvent e) => _onEvent(e);

  @override
  void dispose() {
    _disposed = true;
    _typingTimer?.cancel();
    if (_typing) _incall.setTyping(peerSipUser, false).catchError((Object _) {});
    _sub.cancel();
    super.dispose();
  }
}
