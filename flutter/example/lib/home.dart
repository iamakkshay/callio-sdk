import 'dart:async';

import 'package:flutter/material.dart';
import 'package:incall_flutter/incall_ui.dart';

/// After sign-in: registration state, the directory, a dial pad field, and call history.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onSignedOut, required this.onChat});
  final VoidCallback onSignedOut;
  final void Function(BuildContext context, CallController call) onChat;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _incall = InCall.instance;
  final _dial = TextEditingController();
  StreamSubscription<InCallEvent>? _sub;
  RegistrationState _reg = InCall.instance.registrationState;
  InCallSession? _session;
  List<HistoryEntry> _history = const [];
  Map<String, bool> _presence = const {};
  final _unread = <String, int>{};
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _sub = _incall.events.listen(_onEvent);
    _refresh();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _dial.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final s = await _incall.session();
      final h = await _incall.callHistory(limit: 30);
      if (!mounted) return;
      setState(() {
        _session = s;
        _history = h;
      });
      if (s != null && s.directory.isNotEmpty) {
        unawaited(_incall.startPresenceUpdates().catchError((Object _) {}));
      }
    } catch (e) {
      _toast('Could not load: $e');
    }
  }

  void _onEvent(InCallEvent e) {
    switch (e) {
      case RegistrationChanged(:final state):
        setState(() => _reg = state);
        if (state == RegistrationState.registered && _session == null) _refresh();
      case MessageReceived(:final peerSip):
        setState(() => _unread[peerSip] = (_unread[peerSip] ?? 0) + 1);
      case PresenceChanged(:final presence):
        setState(() => _presence = presence);
      case CallStateChanged(:final status):
        if (status == CallStatus.ended) _refresh();
      case CallFailed(:final message):
        _toast(message);
      default:
        break;
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _call(String sipUser, {Contact? contact}) async {
    if (sipUser.trim().isEmpty) return;
    try {
      await CallioCalls.dial(Navigator.of(context), sipUser.trim(), contact: contact, onChat: widget.onChat);
    } on InCallException catch (e) {
      _toast('Call failed: ${e.message}');
    }
  }

  void _chat(String sipUser, String title) {
    setState(() => _unread.remove(sipUser));
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        peerSipUser: sipUser,
        title: title,
        onCall: () => _call(sipUser),
        // A real app would read the device location here (with its own permission prompt).
        locationProvider: () async => const SharedLocation(lat: 24.7136, lng: 46.6753, label: 'Riyadh (demo)'),
      ),
    ));
  }

  Future<void> _signOut() async {
    try {
      await _incall.stopPresenceUpdates();
      await _incall.stop();
    } catch (_) {}
    widget.onSignedOut();
  }

  @override
  Widget build(BuildContext context) {
    final features = _session?.features ?? const Features();
    final pages = [_contacts(features), _dialer(features), _historyList()];
    return Scaffold(
      appBar: AppBar(
        title: Text(_session?.user.isNotEmpty == true ? _session!.user : 'Callio'),
        actions: [
          Padding(padding: const EdgeInsetsDirectional.only(end: 4), child: _RegistrationChip(state: _reg)),
          IconButton(tooltip: 'Sign out', icon: const Icon(Icons.logout_outlined), onPressed: _signOut),
        ],
      ),
      body: RefreshIndicator(onRefresh: _refresh, child: pages[_tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.people_outline), label: 'Contacts'),
          NavigationDestination(icon: Icon(Icons.dialpad_outlined), label: 'Dial'),
          NavigationDestination(icon: Icon(Icons.history_outlined), label: 'History'),
        ],
      ),
    );
  }

  Widget _contacts(Features features) {
    final dir = _session?.directory ?? const <Contact>[];
    if (dir.isEmpty) {
      return ListView(children: const [
        SizedBox(height: 120),
        Center(child: Text('No contacts in your directory.\nUse the Dial tab to call an extension.', textAlign: TextAlign.center)),
      ]);
    }
    return ListView.separated(
      itemCount: dir.length,
      separatorBuilder: (_, __) => const Divider(indent: 72),
      itemBuilder: (context, i) {
        final c = dir[i];
        final online = _presence[c.sipUser];
        final unread = _unread[c.sipUser] ?? 0;
        return ListTile(
          leading: Stack(children: [
            CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
              child: Text(CallioAvatar.initials(c.displayName)),
            ),
            if (online != null)
              PositionedDirectional(
                end: 0,
                bottom: 0,
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: online ? CallioColors.mint : Theme.of(context).colorScheme.outline,
                    border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
                  ),
                ),
              ),
          ]),
          title: Text(c.displayName),
          subtitle: Text('${c.sipUser} · ${c.userType}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (features.chat)
              Badge(
                isLabelVisible: unread > 0,
                label: Text('$unread'),
                child: IconButton(tooltip: 'Chat', icon: const Icon(Icons.chat_bubble_outline), onPressed: () => _chat(c.sipUser, c.displayName)),
              ),
            if (features.calling)
              IconButton(tooltip: 'Call', icon: const Icon(Icons.call_outlined), onPressed: () => _call(c.sipUser, contact: c)),
          ]),
        );
      },
    );
  }

  Widget _dialer(Features features) => ListView(padding: const EdgeInsets.all(20), children: [
        TextField(
          controller: _dial,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Extension or username', prefixIcon: Icon(Icons.dialpad_outlined)),
          onSubmitted: (v) => _call(v),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: features.calling && _reg == RegistrationState.registered ? () => _call(_dial.text) : null,
              icon: const Icon(Icons.call_outlined),
              label: const Text('Call'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: features.chat && _dial.text.trim().isNotEmpty ? () => _chat(_dial.text.trim(), _dial.text.trim()) : null,
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Chat'),
            ),
          ),
        ]),
        if (_reg != RegistrationState.registered)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text('Calls are available once the line is registered.'),
          ),
      ]);

  Widget _historyList() {
    if (_history.isEmpty) {
      return ListView(children: const [SizedBox(height: 120), Center(child: Text('No calls yet.'))]);
    }
    return ListView.separated(
      itemCount: _history.length,
      separatorBuilder: (_, __) => const Divider(indent: 72),
      itemBuilder: (context, i) {
        final h = _history[i];
        final missed = h.outcome == 'missed' || h.outcome == 'no-answer';
        return ListTile(
          leading: Icon(
            h.direction == CallDirection.outgoing ? Icons.call_made_outlined : Icons.call_received_outlined,
            color: missed ? Theme.of(context).colorScheme.error : null,
          ),
          title: Text(h.peerDisplayName),
          subtitle: Text('${h.outcome} · ${formatCallDuration(Duration(seconds: h.durationSec))} · ${h.at.replaceFirst('T', ' ').split('.').first}'),
          trailing: IconButton(
            tooltip: 'Call back',
            icon: const Icon(Icons.call_outlined),
            onPressed: () => _call(h.peerSipUser ?? h.peer),
          ),
        );
      },
    );
  }
}

class _RegistrationChip extends StatelessWidget {
  const _RegistrationChip({required this.state});
  final RegistrationState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (state) {
      RegistrationState.registered => ('Online', CallioColors.mint),
      RegistrationState.connecting => ('Connecting', CallioColors.amber),
      RegistrationState.offline => ('Offline', scheme.outline),
    };
    return Semantics(
      label: 'Line $label',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: scheme.outlineVariant)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
        ]),
      ),
    );
  }
}
