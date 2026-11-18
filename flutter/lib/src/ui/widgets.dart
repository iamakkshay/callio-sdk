import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import 'strings.dart';
import 'theme.dart';

/// Initials in a circle, with an optional pulsing ring (ringing calls).
class CallioAvatar extends StatefulWidget {
  const CallioAvatar({super.key, required this.name, this.size = 112, this.pulse = false, this.color, this.foreground});

  final String name;
  final double size;
  final bool pulse;
  final Color? color, foreground;

  static String initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    final first = parts.first.characters.first;
    final last = parts.length > 1 ? parts.last.characters.first : '';
    return (first + last).toUpperCase();
  }

  @override
  State<CallioAvatar> createState() => _CallioAvatarState();
}

class _CallioAvatarState extends State<CallioAvatar> with SingleTickerProviderStateMixin {
  late final AnimationController _ring = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(CallioAvatar old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final animate = widget.pulse && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (animate && !_ring.isAnimating) {
      _ring.repeat();
    } else if (!animate && _ring.isAnimating) {
      _ring.stop();
      _ring.value = 0;
    }
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fill = widget.color ?? Colors.white.withValues(alpha: 0.16);
    final fg = widget.foreground ?? Colors.white;
    final text = CallioAvatar.initials(widget.name);
    final core = Container(
      width: widget.size,
      height: widget.size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: fill),
      child: text.isEmpty
          ? Icon(Icons.person_outline, size: widget.size * 0.46, color: fg)
          : Text(text, style: TextStyle(color: fg, fontSize: widget.size * 0.34, fontWeight: FontWeight.w600, letterSpacing: 1)),
    );
    return ExcludeSemantics(
      child: SizedBox(
        width: widget.size * 1.5,
        height: widget.size * 1.5,
        child: AnimatedBuilder(
          animation: _ring,
          builder: (context, child) => CustomPaint(
            painter: _RingPainter(progress: widget.pulse ? _ring.value : 0, color: fg, radius: widget.size / 2),
            child: Center(child: child),
          ),
          child: core,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.color, required this.radius});
  final double progress, radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final c = size.center(Offset.zero);
    for (final offset in [0.0, 0.5]) {
      final p = (progress + offset) % 1.0;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color.withValues(alpha: (1 - p) * 0.45);
      canvas.drawCircle(c, radius + p * radius * 0.5, paint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress || old.color != color;
}

/// A round call control with a label underneath (mute, speaker, hold, keypad, ...).
class CallControlButton extends StatelessWidget {
  const CallControlButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.active = false,
    this.fill,
    this.foreground,
    this.size = 64,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool active;
  final Color? fill, foreground;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final style = CallioCallStyle.of(context);
    final bg = fill ?? (active ? style.controlActiveFill : style.controlFill);
    final fg = foreground ?? (active ? style.controlActiveForeground : style.foreground);
    final enabled = onPressed != null;
    final tap = onPressed == null
        ? null
        : () {
            HapticFeedback.selectionClick();
            onPressed!();
          };
    return Semantics(
      button: true,
      toggled: fill == null ? active : null,
      enabled: enabled,
      label: tooltip ?? label,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Material(
            color: bg,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: tap,
              child: SizedBox(width: size, height: size, child: Icon(icon, color: fg, size: size * 0.42)),
            ),
          ),
          // The label is part of the touch target too.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: tap,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(label, style: TextStyle(color: style.mutedForeground, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Three signal bars and an optional label for the call's quality (from MOS, else RTT and loss).
class CallQualityIndicator extends StatelessWidget {
  const CallQualityIndicator({super.key, required this.quality, this.color, this.showLabel = true, this.strings = const CallioStrings()});

  final CallQuality? quality;
  final Color? color;
  final bool showLabel;
  final CallioStrings strings;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? CallioCallStyle.of(context).foreground;
    final q = quality;
    final bars = q?.bars ?? 0;
    final label = switch (bars) { 3 => strings.qualityGood, 2 => strings.qualityFair, 1 => strings.qualityPoor, _ => strings.qualityUnknown };
    final barColor = switch (bars) { 1 => CallioColors.amber, _ => fg };
    final detail = q?.rttMs != null ? ' ${q!.rttMs} ms' : '';
    return Semantics(
      label: '$label$detail',
      excludeSemantics: true,
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var i = 0; i < 3; i++)
          Container(
            margin: const EdgeInsetsDirectional.only(end: 2),
            width: 4,
            height: 6.0 + i * 4,
            decoration: BoxDecoration(
              color: i < bars ? barColor : fg.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
        if (showLabel) ...[
          const SizedBox(width: 8),
          Text('$label$detail', style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 12)),
        ],
      ]),
    );
  }
}

/// A 12-key phone keypad. Each press calls [onKey] with 0-9, * or #.
class CallioDialPad extends StatelessWidget {
  const CallioDialPad({super.key, required this.onKey, this.foreground, this.keySize = 68});

  final ValueChanged<String> onKey;
  final Color? foreground;
  final double keySize;

  static const _keys = [
    ('1', ''), ('2', 'ABC'), ('3', 'DEF'),
    ('4', 'GHI'), ('5', 'JKL'), ('6', 'MNO'),
    ('7', 'PQRS'), ('8', 'TUV'), ('9', 'WXYZ'),
    ('*', ''), ('0', '+'), ('#', ''),
  ];

  @override
  Widget build(BuildContext context) {
    final style = CallioCallStyle.of(context);
    final fg = foreground ?? style.foreground;
    return Directionality(
      // Keypads keep their layout in right-to-left locales.
      textDirection: TextDirection.ltr,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var row = 0; row < 4; row++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              for (var col = 0; col < 3; col++) _key(_keys[row * 3 + col], fg, style),
            ]),
          ),
      ]),
    );
  }

  Widget _key((String, String) k, Color fg, CallioCallStyle style) => Semantics(
        button: true,
        label: k.$1,
        excludeSemantics: true,
        child: Material(
          color: style.controlFill,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              HapticFeedback.lightImpact();
              onKey(k.$1);
            },
            child: SizedBox(
              width: keySize,
              height: keySize,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(k.$1, style: TextStyle(color: fg, fontSize: keySize * 0.38, fontWeight: FontWeight.w500, height: 1.1)),
                if (k.$2.isNotEmpty) Text(k.$2, style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 10, letterSpacing: 1.2)),
              ]),
            ),
          ),
        ),
      );
}

/// mm:ss (or h:mm:ss) for a call timer.
String formatCallDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}
