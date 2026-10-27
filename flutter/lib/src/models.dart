// Public value types for the In-Call Flutter plugin — mirror the native SDK models
// (docs/SDK_API_CONTRACT.md). Decoded from the method/event channel maps.

enum RegistrationState { connecting, registered, offline }

enum CallDirection { incoming, outgoing }

enum MessageSender { me, peer }

RegistrationState _regState(String? s) => switch (s) {
      'connecting' => RegistrationState.connecting,
      'registered' => RegistrationState.registered,
      _ => RegistrationState.offline,
    };

class Features {
  final bool calling, chat, location, recording;
  const Features({this.calling = true, this.chat = true, this.location = true, this.recording = false});

  factory Features.fromMap(Map m) => Features(
        calling: m['calling'] ?? true,
        chat: m['chat'] ?? true,
        location: m['location'] ?? true,
        recording: m['recording'] ?? false,
      );
}

class Contact {
  final String name, sipUser, displayName, userType;
  const Contact({required this.name, required this.sipUser, required this.displayName, required this.userType});

  factory Contact.fromMap(Map m) => Contact(
        name: m['name'] ?? '',
        sipUser: m['sipUser'] ?? '',
        displayName: m['displayName'] ?? m['name'] ?? '',
        userType: m['userType'] ?? 'customer',
      );
}

class CallQuality {
  final int? rttMs, jitterMs;
  final double? lossPct, mos;
  const CallQuality({this.rttMs, this.jitterMs, this.lossPct, this.mos});

  factory CallQuality.fromMap(Map m) => CallQuality(
        rttMs: (m['rttMs'] as num?)?.toInt(),
        jitterMs: (m['jitterMs'] as num?)?.toInt(),
        lossPct: (m['lossPct'] as num?)?.toDouble(),
        mos: (m['mos'] as num?)?.toDouble(),
      );
}

class SharedLocation {
  final double lat, lng;
  final String label;
  const SharedLocation({required this.lat, required this.lng, this.label = 'Shared location'});

  factory SharedLocation.fromMap(Map m) =>
      SharedLocation(lat: (m['lat'] as num).toDouble(), lng: (m['lng'] as num).toDouble(), label: m['label'] ?? 'Shared location');
}

class Message {
  final String id;
  final MessageSender from;
  final String? text;
  final SharedLocation? location;
  final String status;
  const Message({required this.id, required this.from, this.text, this.location, this.status = 'delivered'});

  factory Message.fromMap(Map m) => Message(
        id: m['id'] ?? '',
        from: m['from'] == 'me' ? MessageSender.me : MessageSender.peer,
        text: m['text'],
        location: m['location'] is Map ? SharedLocation.fromMap(m['location']) : null,
        status: m['status'] ?? 'delivered',
      );
}

class HistoryEntry {
  final String callId, peer, peerDisplayName, outcome, at;
  final CallDirection direction;
  final int durationSec;
  const HistoryEntry({
    required this.callId,
    required this.peer,
    required this.peerDisplayName,
    required this.direction,
    required this.outcome,
    required this.durationSec,
    required this.at,
  });

  factory HistoryEntry.fromMap(Map m) => HistoryEntry(
        callId: m['callId'] ?? '',
        peer: m['peer'] ?? '',
        peerDisplayName: m['peerDisplayName'] ?? m['peer'] ?? '',
        direction: m['direction'] == 'outgoing' ? CallDirection.outgoing : CallDirection.incoming,
        outcome: m['outcome'] ?? '',
        durationSec: (m['durationSec'] as num?)?.toInt() ?? 0,
        at: m['at'] ?? '',
      );
}

// ---- events (from the EventChannel) ----

sealed class InCallEvent {
  const InCallEvent();

  factory InCallEvent.fromMap(dynamic raw) {
    final m = Map<String, dynamic>.from(raw as Map);
    return switch (m['event']) {
      'registration' => RegistrationChanged(_regState(m['state'])),
      'incomingCall' => IncomingCall(callId: m['callId'] ?? '', from: m['from'] is Map ? Contact.fromMap(m['from']) : null),
      'callState' => CallStateChanged(callId: m['callId'] ?? '', state: m['state'] ?? ''),
      'quality' => QualityUpdated(CallQuality.fromMap(m['quality'] ?? const {})),
      'message' => MessageReceived(message: Message.fromMap(m['message'] ?? const {}), peerSip: m['peerSip'] ?? ''),
      'audioRoute' => AudioRouteChanged(m['route'] ?? 'earpiece'),
      _ => CallFailed(code: m['code'] ?? 'unknown', message: m['message'] ?? 'unknown event'),
    };
  }
}

class RegistrationChanged extends InCallEvent {
  final RegistrationState state;
  const RegistrationChanged(this.state);
}

class IncomingCall extends InCallEvent {
  final String callId;
  final Contact? from;
  const IncomingCall({required this.callId, this.from});
}

class CallStateChanged extends InCallEvent {
  final String callId;
  final String state; // initiating | ringing | connected | onHold | reconnecting | ended
  const CallStateChanged({required this.callId, required this.state});
}

class QualityUpdated extends InCallEvent {
  final CallQuality quality;
  const QualityUpdated(this.quality);
}

class MessageReceived extends InCallEvent {
  final Message message;
  final String peerSip;
  const MessageReceived({required this.message, required this.peerSip});
}

/// Call audio moved: 'earpiece', 'speaker' or 'bluetooth' (FR-CALL-04).
class AudioRouteChanged extends InCallEvent {
  final String route;
  const AudioRouteChanged(this.route);
}

class CallFailed extends InCallEvent {
  final String code, message;
  const CallFailed({required this.code, required this.message});
}
