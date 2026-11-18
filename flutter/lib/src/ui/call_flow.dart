import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers.dart';
import '../incall.dart';
import '../models.dart';
import 'call_screens.dart';
import 'strings.dart';

/// One call from ring (or dial) to hang-up on a single route: the incoming screen until answered, then the
/// in-call screen. Owns and disposes its [CallController].
class CallFlowScreen extends StatefulWidget {
  const CallFlowScreen({super.key, required this.controller, this.onChat, this.strings = const CallioStrings()});

  final CallController controller;
  final void Function(BuildContext context, CallController call)? onChat;
  final CallioStrings strings;

  @override
  State<CallFlowScreen> createState() => _CallFlowScreenState();
}

class _CallFlowScreenState extends State<CallFlowScreen> {
  late bool _ringing = widget.controller.isRinging;

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (_ringing) {
      return IncomingCallScreen(
        controller: c,
        strings: widget.strings,
        onAnswered: () => setState(() => _ringing = false),
      );
    }
    return InCallScreen(
      controller: c,
      strings: widget.strings,
      onChat: widget.onChat == null ? null : () => widget.onChat!(context, c),
    );
  }
}

/// Helpers that put the ready-made call screens on a navigator.
abstract final class CallioCalls {
  /// Dial [sipUser] and show the in-call screen right away (Calling, Ringing, then the timer).
  /// Throws [InCallException] if the SDK refuses (not registered, calling disabled, ...); the screen closes.
  static Future<Call> dial(
    NavigatorState navigator,
    String sipUser, {
    Contact? contact,
    InCall? incall,
    CallioStrings strings = const CallioStrings(),
    void Function(BuildContext context, CallController call)? onChat,
  }) async {
    final sdk = incall ?? InCall.instance;
    final controller = CallController(incall: sdk, peerSipUser: sipUser, peer: contact);
    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => CallFlowScreen(controller: controller, strings: strings, onChat: onChat),
    );
    unawaited(navigator.push(route));
    try {
      return await sdk.dial(sipUser);
    } catch (_) {
      if (route.isActive) navigator.removeRoute(route);
      rethrow;
    }
  }

  /// Show the incoming-call screen for [event] (then the in-call screen once answered).
  static Future<void> presentIncoming(
    NavigatorState navigator,
    IncomingCall event, {
    InCall? incall,
    CallioStrings strings = const CallioStrings(),
    void Function(BuildContext context, CallController call)? onChat,
  }) =>
      navigator.push(MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => CallFlowScreen(controller: CallController.incoming(event, incall: incall), strings: strings, onChat: onChat),
      ));
}

/// Wrap your app (inside MaterialApp.builder, or around the home) to show the incoming-call screen whenever a
/// call rings while the app is open:
///
/// ```dart
/// final navigatorKey = GlobalKey<NavigatorState>();
/// MaterialApp(
///   navigatorKey: navigatorKey,
///   builder: (context, child) => CallioCallListener(navigatorKey: navigatorKey, child: child!),
/// )
/// ```
class CallioCallListener extends StatefulWidget {
  const CallioCallListener({
    super.key,
    required this.navigatorKey,
    required this.child,
    this.incall,
    this.strings = const CallioStrings(),
    this.onChat,
    this.enabled = true,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  final InCall? incall;
  final CallioStrings strings;
  final void Function(BuildContext context, CallController call)? onChat;
  final bool enabled;

  @override
  State<CallioCallListener> createState() => _CallioCallListenerState();
}

class _CallioCallListenerState extends State<CallioCallListener> {
  StreamSubscription<InCallEvent>? _sub;
  String? _showing;

  @override
  void initState() {
    super.initState();
    _sub = (widget.incall ?? InCall.instance).events.listen(_onEvent, onError: (Object _) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(InCallEvent e) {
    if (!widget.enabled || e is! IncomingCall || e.callId == _showing) return;
    final nav = widget.navigatorKey.currentState;
    if (nav == null) return;
    _showing = e.callId;
    CallioCalls.presentIncoming(nav, e, incall: widget.incall, strings: widget.strings, onChat: widget.onChat)
        .whenComplete(() => _showing = null);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
