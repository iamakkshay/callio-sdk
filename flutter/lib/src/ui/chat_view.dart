import 'package:flutter/material.dart';

import '../controllers.dart';
import '../models.dart';
import 'strings.dart';

/// A simple 1:1 chat: message bubbles with delivery status, location cards and a composer.
/// Embed it in your own Scaffold (it has no app bar), or use ChatScreen.
class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.controller,
    this.locationProvider,
    this.onOpenLocation,
    this.strings = const CallioStrings(),
    this.loadOnStart = true,
  });

  final ChatController controller;

  /// Shows a Share location button; return the location to send (your app owns the location permission).
  final Future<SharedLocation?> Function()? locationProvider;

  /// Tapping a location card (open your map).
  final void Function(SharedLocation location)? onOpenLocation;
  final CallioStrings strings;

  /// Load the messages the native SDK already holds when the view appears.
  final bool loadOnStart;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _text = TextEditingController();
  final _scroll = ScrollController();

  ChatController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    if (widget.loadOnStart) _c.load();
  }

  @override
  void didUpdateWidget(ChatView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    try {
      await _c.sendText(t);
    } catch (_) {
      // Shown as "Not sent" on the bubble.
    }
  }

  Future<void> _shareLocation() async {
    final loc = await widget.locationProvider?.call();
    if (loc == null) return;
    try {
      await _c.sendLocation(loc);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    final scheme = Theme.of(context).colorScheme;
    final msgs = _c.messages.reversed.toList(); // newest at the bottom of a reversed list

    return Column(children: [
      Expanded(
        child: msgs.isEmpty
            ? Center(
                child: _c.isLoading
                    ? const CircularProgressIndicator()
                    : Text(s.noMessages, style: TextStyle(color: scheme.onSurfaceVariant)),
              )
            : ListView.builder(
                controller: _scroll,
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                itemCount: msgs.length,
                itemBuilder: (context, i) => _Bubble(message: msgs[i], strings: s, onOpenLocation: widget.onOpenLocation),
              ),
      ),
      const Divider(height: 1),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 8, 8),
          child: Row(children: [
            if (widget.locationProvider != null)
              IconButton(
                tooltip: s.shareLocation,
                icon: const Icon(Icons.place_outlined),
                onPressed: _shareLocation,
              ),
            Expanded(
              child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: s.messageHint,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
                onChanged: (v) => v.isEmpty ? _c.stopTyping() : _c.typing(),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 4),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _text,
              builder: (context, v, _) => IconButton.filled(
                tooltip: s.send,
                icon: const Icon(Icons.send_outlined),
                onPressed: v.text.trim().isEmpty ? null : _send,
              ),
            ),
          ]),
        ),
      ),
    ]);
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.strings, this.onOpenLocation});
  final Message message;
  final CallioStrings strings;
  final void Function(SharedLocation)? onOpenLocation;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.from == MessageSender.me;
    final bg = mine ? scheme.primary : scheme.surfaceContainerHighest;
    final fg = mine ? scheme.onPrimary : scheme.onSurface;
    final loc = message.location;
    final radius = BorderRadiusDirectional.only(
      topStart: const Radius.circular(16),
      topEnd: const Radius.circular(16),
      bottomStart: Radius.circular(mine ? 16 : 4),
      bottomEnd: Radius.circular(mine ? 4 : 16),
    );

    Widget body = loc != null
        ? InkWell(
            onTap: onOpenLocation == null ? null : () => onOpenLocation!(loc),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.place_outlined, color: fg, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(loc.label, style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
                  Text('${loc.lat.toStringAsFixed(5)}, ${loc.lng.toStringAsFixed(5)}',
                      style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 12)),
                ]),
              ),
            ]),
          )
        : Text(message.text ?? '', style: TextStyle(color: fg, fontSize: 15, height: 1.3));

    final status = mine ? _status(message.deliveryStatus, fg) : null;

    return Align(
      alignment: mine ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
        decoration: BoxDecoration(color: bg, borderRadius: radius),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          body,
          if (status != null) ...[const SizedBox(height: 2), status],
        ]),
      ),
    );
  }

  Widget _status(MessageStatus st, Color fg) {
    final (icon, label) = switch (st) {
      MessageStatus.sending => (Icons.schedule, strings.sending),
      MessageStatus.sent => (Icons.done, strings.sent),
      MessageStatus.delivered => (Icons.done_all, strings.delivered),
      MessageStatus.read => (Icons.done_all, strings.read),
      MessageStatus.failed => (Icons.error_outline, strings.failed),
    };
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Icon(icon, size: 14, color: st == MessageStatus.read ? const Color(0xFFBFF0DA) : fg.withValues(alpha: 0.75)),
    );
  }
}

/// ChatView in a Scaffold with a title and an optional call button.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.peerSipUser,
    this.title,
    this.onCall,
    this.locationProvider,
    this.onOpenLocation,
    this.strings = const CallioStrings(),
  });

  final String peerSipUser;
  final String? title;
  final VoidCallback? onCall;
  final Future<SharedLocation?> Function()? locationProvider;
  final void Function(SharedLocation)? onOpenLocation;
  final CallioStrings strings;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatController _controller = ChatController(peerSipUser: widget.peerSipUser);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.title ?? widget.peerSipUser),
          actions: [
            if (widget.onCall != null) IconButton(icon: const Icon(Icons.call_outlined), tooltip: widget.strings.call, onPressed: widget.onCall),
          ],
        ),
        body: ChatView(
          controller: _controller,
          locationProvider: widget.locationProvider,
          onOpenLocation: widget.onOpenLocation,
          strings: widget.strings,
        ),
      );
}
