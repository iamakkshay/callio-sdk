import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers.dart';
import '../models.dart';
import 'strings.dart';
import 'theme.dart';
import 'widgets.dart';

class _CallBackground extends StatelessWidget {
  const _CallBackground({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final style = CallioCallStyle.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [style.backgroundTop, style.backgroundBottom],
        ),
      ),
      // Fill the screen, but scroll instead of overflowing on short screens (landscape, keypad open).
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: IntrinsicHeight(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class _PeerHeader extends StatelessWidget {
  const _PeerHeader({required this.name, required this.status, this.pulse = false});
  final String name, status;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    final style = CallioCallStyle.of(context);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      CallioAvatar(name: name, pulse: pulse, size: 104),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          name,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: style.foreground, fontSize: 28, fontWeight: FontWeight.w600, fontFamily: style.displayFontFamily),
        ),
      ),
      const SizedBox(height: 6),
      Semantics(
        liveRegion: true,
        child: Text(status, style: TextStyle(color: style.mutedForeground, fontSize: 16, fontFeatures: const [FontFeature.tabularFigures()])),
      ),
    ]);
  }
}

/// Full-screen incoming call: caller, pulsing avatar, Answer and Decline.
///
/// With a [controller] the buttons answer / decline through it; [onAnswered] then runs (push the
/// InCallScreen there), and the screen closes itself if the caller hangs up first ([onEnded], default: pop).
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({
    super.key,
    required this.controller,
    this.onAnswered,
    this.onEnded,
    this.subtitle,
    this.strings = const CallioStrings(),
  });

  final CallController controller;
  final VoidCallback? onAnswered;
  final VoidCallback? onEnded;

  /// Shown under the name; defaults to "Incoming call".
  final String? subtitle;
  final CallioStrings strings;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  bool _busy = false, _closed = false;

  CallController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
  }

  @override
  void didUpdateWidget(IncomingCallScreen old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (!_closed && (_c.isEnded || (_c.isConnected && !_busy))) {
      // Ended (caller gave up), or answered somewhere else (lock screen / system UI).
      _closed = true;
      if (_c.isConnected) {
        widget.onAnswered?.call();
      } else {
        (widget.onEnded ?? () => Navigator.of(context).maybePop())();
      }
    }
    setState(() {});
  }

  Future<void> _answer() async {
    setState(() => _busy = true);
    try {
      await _c.answer();
      if (!mounted || _closed) return;
      _closed = true;
      widget.onAnswered?.call();
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decline() async {
    setState(() => _busy = true);
    try {
      await _c.decline();
    } catch (_) {
      // The call may already be gone.
    }
    if (!mounted || _closed) return;
    _closed = true;
    (widget.onEnded ?? () => Navigator.of(context).maybePop())();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    final style = CallioCallStyle.of(context);
    return Scaffold(
      backgroundColor: style.backgroundBottom,
      body: _CallBackground(
        child: Column(children: [
          const Spacer(flex: 2),
          _PeerHeader(name: _c.displayName, status: widget.subtitle ?? s.incomingCall, pulse: !_c.isEnded),
          const Spacer(flex: 3),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 40),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              CallControlButton(
                icon: Icons.call_end_outlined,
                label: s.decline,
                fill: style.endFill,
                foreground: Colors.white,
                size: 72,
                onPressed: _busy ? null : _decline,
              ),
              CallControlButton(
                icon: Icons.call_outlined,
                label: s.answer,
                fill: style.answerFill,
                foreground: CallioColors.ink,
                size: 72,
                onPressed: _busy ? null : _answer,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Full-screen in-call UI: peer, status / timer, quality, and Mute, Keypad, Speaker, Hold and End.
///
/// Works for outgoing calls from the moment you dial (shows Calling, Ringing) and for answered calls.
/// When the call ends it shows the reason briefly, then runs [onClosed] (default: pop the route).
class InCallScreen extends StatefulWidget {
  const InCallScreen({
    super.key,
    required this.controller,
    this.onClosed,
    this.onChat,
    this.closeDelay = const Duration(milliseconds: 1400),
    this.showHold = true,
    this.strings = const CallioStrings(),
  });

  final CallController controller;
  final VoidCallback? onClosed;

  /// Shows a Chat button that runs this (open the conversation with the peer).
  final VoidCallback? onChat;
  final Duration closeDelay;
  final bool showHold;
  final CallioStrings strings;

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  Timer? _ticker, _closeTimer;
  bool _keypad = false;
  String _digits = '';

  CallController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _c.isConnected) setState(() {});
    });
    _changed();
  }

  @override
  void didUpdateWidget(InCallScreen old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _closeTimer?.cancel();
    _c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (_c.isEnded && _closeTimer == null) {
      _ticker?.cancel();
      _closeTimer = Timer(widget.closeDelay, () {
        if (!mounted) return;
        (widget.onClosed ?? () => Navigator.of(context).maybePop())();
      });
    }
    setState(() {});
  }

  String _statusText(CallioStrings s) => switch (_c.status) {
        CallStatus.initiating => _c.direction == CallDirection.incoming ? s.connecting : s.calling,
        CallStatus.ringing => _c.direction == CallDirection.incoming ? s.connecting : s.ringing,
        CallStatus.connected => formatCallDuration(_c.elapsed),
        CallStatus.onHold => s.onHold,
        CallStatus.reconnecting => s.reconnecting,
        CallStatus.ended => s.endReason(_c.endReason),
      };

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // The controller already rolled the toggle back; nothing else to do here.
    }
  }

  IconData _routeIcon(AudioRoute r) => switch (r) {
        AudioRoute.speaker => Icons.volume_up_outlined,
        AudioRoute.bluetooth => Icons.bluetooth_audio_outlined,
        AudioRoute.earpiece => Icons.phone_in_talk_outlined,
      };

  String _routeLabel(AudioRoute r, CallioStrings s) => switch (r) {
        AudioRoute.speaker => s.speaker,
        AudioRoute.bluetooth => s.bluetooth,
        AudioRoute.earpiece => s.earpiece,
      };

  Future<void> _pickRoute() async {
    final s = widget.strings;
    if (!_c.availableRoutes.contains(AudioRoute.bluetooth)) return _run(_c.toggleSpeaker);
    final picked = await showModalBottomSheet<AudioRoute>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 24, end: 24, bottom: 8),
            child: Align(alignment: AlignmentDirectional.centerStart, child: Text(s.audioOutput, style: Theme.of(ctx).textTheme.titleMedium)),
          ),
          for (final r in _c.availableRoutes)
            ListTile(
              leading: Icon(_routeIcon(r)),
              title: Text(_routeLabel(r, s)),
              trailing: r == _c.audioRoute ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(ctx).pop(r),
            ),
        ]),
      ),
    );
    if (picked != null) await _run(() => _c.setAudioRoute(picked));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    final style = CallioCallStyle.of(context);
    final live = _c.isConnected;
    final ended = _c.isEnded;
    final route = _c.audioRoute;
    final multiRoute = _c.availableRoutes.contains(AudioRoute.bluetooth);

    final controls = Wrap(
      alignment: WrapAlignment.center,
      spacing: 28,
      runSpacing: 22,
      children: [
        CallControlButton(
          icon: _c.isMuted ? Icons.mic_off_outlined : Icons.mic_none_outlined,
          label: _c.isMuted ? s.unmute : s.mute,
          active: _c.isMuted,
          onPressed: ended ? null : () => _run(_c.toggleMute),
        ),
        CallControlButton(
          icon: Icons.dialpad_outlined,
          label: s.keypad,
          onPressed: live && !ended ? () => setState(() => _keypad = true) : null,
        ),
        CallControlButton(
          icon: multiRoute ? _routeIcon(route) : Icons.volume_up_outlined,
          label: multiRoute ? _routeLabel(route, s) : s.speaker,
          active: route == AudioRoute.speaker || (multiRoute && route == AudioRoute.bluetooth),
          onPressed: ended ? null : _pickRoute,
        ),
        if (widget.showHold)
          CallControlButton(
            icon: _c.isOnHold ? Icons.play_arrow_outlined : Icons.pause_outlined,
            label: _c.isOnHold ? s.resume : s.hold,
            active: _c.isOnHold,
            onPressed: live && !ended ? () => _run(_c.toggleHold) : null,
          ),
        if (widget.onChat != null) CallControlButton(icon: Icons.chat_bubble_outline, label: s.chat, onPressed: widget.onChat),
      ],
    );

    final keypad = Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: 36,
        child: Text(_digits,
            style: TextStyle(color: style.foreground, fontSize: 28, letterSpacing: 2, fontFeatures: const [FontFeature.tabularFigures()])),
      ),
      CallioDialPad(onKey: (k) {
        setState(() => _digits = (_digits + k).length > 24 ? (_digits + k).substring(1) : _digits + k);
        _run(() => _c.sendDtmf(k));
      }),
      TextButton(
        onPressed: () => setState(() => _keypad = false),
        child: Text(s.hideKeypad, style: TextStyle(color: style.foreground)),
      ),
    ]);

    return Scaffold(
      backgroundColor: style.backgroundBottom,
      body: _CallBackground(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: AnimatedOpacity(
              opacity: live ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: CallQualityIndicator(quality: _c.quality, strings: s),
            ),
          ),
          const Spacer(),
          if (!_keypad) _PeerHeader(name: _c.displayName, status: _statusText(s), pulse: !live && !ended && _c.status != CallStatus.ended),
          if (_keypad)
            Text(_c.displayName, style: TextStyle(color: style.mutedForeground, fontSize: 16)),
          const Spacer(),
          AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: _keypad ? keypad : controls),
          const SizedBox(height: 28),
          Padding(
            padding: const EdgeInsets.only(bottom: 36),
            child: CallControlButton(
              icon: Icons.call_end_outlined,
              label: ended ? s.endReason(_c.endReason) : s.end,
              fill: style.endFill,
              foreground: Colors.white,
              size: 72,
              onPressed: ended ? null : () => _run(_c.end),
            ),
          ),
        ]),
      ),
    );
  }
}
