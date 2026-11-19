// Public value types for the Callio Flutter plugin. They mirror the native SDK models
// (docs/SDK_API_CONTRACT.md) and are decoded from the method/event channel maps.

enum RegistrationState { connecting, registered, offline }

enum CallDirection { incoming, outgoing }

enum MessageSender { me, peer }

/// Delivery state of a chat message (FR-CHAT-02).
/// `queued`: the peer wasn't connected, so the platform holds the message and delivers it when they're back.
enum MessageStatus { sending, sent, delivered, read, failed, queued }

/// Where call audio plays (FR-CALL-04).
enum AudioRoute { earpiece, speaker, bluetooth }

/// Call lifecycle states, exactly the native SDKs' (FR-CALL-05).
enum CallStatus { initiating, ringing, connected, onHold, reconnecting, ended }

RegistrationState _regState(Object? s) => switch (s) {
      'connecting' => RegistrationState.connecting,
      'registered' => RegistrationState.registered,
      _ => RegistrationState.offline,
    };

MessageStatus _msgStatus(Object? s) => MessageStatus.values.firstWhere((v) => v.name == s, orElse: () => MessageStatus.delivered);

AudioRoute audioRouteFromWire(Object? s) => AudioRoute.values.firstWhere((v) => v.name == s, orElse: () => AudioRoute.earpiece);

CallStatus callStatusFromWire(Object? s) => CallStatus.values.firstWhere((v) => v.name == s, orElse: () => CallStatus.ended);

Map<String, dynamic> _map(Object? raw) => raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};

/// Per-tenant feature flags. The SDK and the ready-made widgets honour them (FR-MT).
class Features {
  final bool calling, chat, location, recording;
  const Features({this.calling = true, this.chat = true, this.location = true, this.recording = false});

  factory Features.fromMap(Map m) => Features(
        calling: m['calling'] as bool? ?? true,
        chat: m['chat'] as bool? ?? true,
        location: m['location'] as bool? ?? true,
        recording: m['recording'] as bool? ?? false,
      );
}

/// A person the user can call or message.
class Contact {
  final String name, sipUser, displayName, userType;
  const Contact({required this.name, required this.sipUser, required this.displayName, required this.userType});

  factory Contact.fromMap(Map m) => Contact(
        name: m['name'] as String? ?? '',
        sipUser: m['sipUser'] as String? ?? '',
        displayName: (m['displayName'] as String?) ?? (m['name'] as String?) ?? '',
        userType: m['userType'] as String? ?? 'customer',
      );

  /// A contact known only by its SIP extension.
  factory Contact.sip(String sipUser) => Contact(name: sipUser, sipUser: sipUser, displayName: sipUser, userType: 'customer');

  Map<String, Object?> toMap() => {'name': name, 'sipUser': sipUser, 'displayName': displayName, 'userType': userType};
}

/// The signed-in user's session, as the platform returned it (no SIP credentials cross the channel).
class InCallSession {
  final String tenant, user, sipUser, userType;
  final Features features;
  final List<Contact> directory, peers, transferTargets;
  const InCallSession({
    required this.tenant,
    required this.user,
    required this.sipUser,
    required this.userType,
    required this.features,
    this.directory = const [],
    this.peers = const [],
    this.transferTargets = const [],
  });

  static List<Contact> _contacts(Object? raw) =>
      raw is List ? raw.whereType<Map>().map(Contact.fromMap).toList() : const <Contact>[];

  factory InCallSession.fromMap(Map m) => InCallSession(
        tenant: m['tenant'] as String? ?? '',
        user: m['user'] as String? ?? '',
        sipUser: m['sipUser'] as String? ?? '',
        userType: m['userType'] as String? ?? 'customer',
        features: Features.fromMap(_map(m['features'])),
        directory: _contacts(m['directory']),
        peers: _contacts(m['peers']),
        transferTargets: _contacts(m['transferTargets']),
      );
}

/// Live call quality (FR-CALL-11). `mos` is null until MOS scoring lands natively.
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

  /// 0 (unknown) to 3 (good), from MOS when present, otherwise from round-trip time and packet loss.
  int get bars {
    final m = mos;
    if (m != null) return m >= 4.0 ? 3 : m >= 3.4 ? 2 : 1;
    final rtt = rttMs, loss = lossPct;
    if (rtt == null && loss == null) return 0;
    final r = rtt ?? 0, l = loss ?? 0;
    if (r < 250 && l < 2) return 3;
    if (r < 450 && l < 6) return 2;
    return 1;
  }
}

class SharedLocation {
  final double lat, lng;
  final String label;
  const SharedLocation({required this.lat, required this.lng, this.label = 'Shared location'});

  factory SharedLocation.fromMap(Map m) => SharedLocation(
        lat: (m['lat'] as num).toDouble(),
        lng: (m['lng'] as num).toDouble(),
        label: m['label'] as String? ?? 'Shared location',
      );
}

class Message {
  final String id;
  final MessageSender from;
  final String? text;
  final SharedLocation? location;

  /// Wire value: sending, sent, delivered, read or failed. See [deliveryStatus].
  final String status;
  const Message({required this.id, required this.from, this.text, this.location, this.status = 'delivered'});

  MessageStatus get deliveryStatus => _msgStatus(status);

  factory Message.fromMap(Map m) => Message(
        id: m['id'] as String? ?? '',
        from: m['from'] == 'me' ? MessageSender.me : MessageSender.peer,
        text: m['text'] as String?,
        location: m['location'] is Map ? SharedLocation.fromMap(m['location'] as Map) : null,
        status: m['status'] as String? ?? 'delivered',
      );

  Message copyWith({String? status}) => Message(id: id, from: from, text: text, location: location, status: status ?? this.status);
}

class HistoryEntry {
  final String callId, peer, peerDisplayName, outcome, at;
  final String? peerSipUser;
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
    this.peerSipUser,
  });

  factory HistoryEntry.fromMap(Map m) => HistoryEntry(
        callId: m['callId'] as String? ?? '',
        peer: m['peer'] as String? ?? '',
        peerDisplayName: (m['peerDisplayName'] as String?) ?? (m['peer'] as String?) ?? '',
        peerSipUser: m['peerSipUser'] as String?,
        direction: m['direction'] == 'outgoing' ? CallDirection.outgoing : CallDirection.incoming,
        outcome: m['outcome'] as String? ?? '',
        durationSec: (m['durationSec'] as num?)?.toInt() ?? 0,
        at: m['at'] as String? ?? '',
      );
}

/// Available and current audio outputs for the call.
class AudioRoutes {
  final List<AudioRoute> available;
  final AudioRoute current;
  const AudioRoutes({required this.available, required this.current});

  factory AudioRoutes.fromMap(Map m) => AudioRoutes(
        available: (m['available'] is List ? m['available'] as List : const []).map(audioRouteFromWire).toSet().toList(),
        current: audioRouteFromWire(m['current']),
      );
}

/// An invitation into a 3-way call. Join with `InCall.joinConference(invite.room)`.
class ConferenceInvite {
  final String room;
  final Contact from;
  final List<String> withSipUsers;
  const ConferenceInvite({required this.room, required this.from, this.withSipUsers = const []});

  factory ConferenceInvite.fromMap(Map m) => ConferenceInvite(
        room: m['room'] as String? ?? '',
        from: Contact.fromMap(_map(m['from'])),
        withSipUsers: (m['with'] is List ? m['with'] as List : const []).map((e) => '$e').toList(),
      );
}

/// Stable error codes (contract section 7). Unknown native codes map to [unknown].
enum InCallErrorCode {
  notRegistered,
  micPermission,
  peerUnreachable,
  busy,
  tokenExpired,
  featureDisabled,
  network,
  mediaFailed,
  noActiveCall,
  invalidArgument,
  unknown,
}

InCallErrorCode errorCodeFromWire(Object? s) =>
    InCallErrorCode.values.firstWhere((v) => v.name == s, orElse: () => InCallErrorCode.unknown);

/// Thrown by [InCall] methods when the native SDK reports a failure.
class InCallException implements Exception {
  final InCallErrorCode code;

  /// The code as the native side sent it (useful when [code] is [InCallErrorCode.unknown]).
  final String rawCode;
  final String message;
  const InCallException(this.code, this.message, {this.rawCode = ''});

  @override
  String toString() => 'InCallException(${code.name}${rawCode.isNotEmpty && rawCode != code.name ? '/$rawCode' : ''}): $message';
}

// ---- events (from the EventChannel) ----

sealed class InCallEvent {
  const InCallEvent();

  factory InCallEvent.fromMap(dynamic raw) {
    final m = _map(raw);
    return switch (m['event']) {
      'registration' => RegistrationChanged(_regState(m['state'])),
      'incomingCall' => IncomingCall(callId: m['callId'] as String? ?? '', from: m['from'] is Map ? Contact.fromMap(m['from'] as Map) : null),
      'callState' => CallStateChanged(
          callId: m['callId'] as String? ?? '',
          state: m['state'] as String? ?? '',
          reason: m['reason'] as String?,
          direction: m['direction'] == 'incoming'
              ? CallDirection.incoming
              : m['direction'] == 'outgoing'
                  ? CallDirection.outgoing
                  : null,
          peer: m['peer'] is Map ? Contact.fromMap(m['peer'] as Map) : null,
          muted: m['muted'] as bool?,
          held: m['held'] as bool?,
        ),
      'quality' => QualityUpdated(CallQuality.fromMap(_map(m['quality'])), callId: m['callId'] as String?),
      'message' => MessageReceived(message: Message.fromMap(_map(m['message'])), peerSip: m['peerSip'] as String? ?? ''),
      'messageStatus' => MessageStatusChanged(
          messageId: m['messageId'] as String? ?? '',
          status: _msgStatus(m['status']),
          peerSip: m['peerSip'] as String?,
        ),
      'audioRoute' => AudioRouteChanged(m['route'] as String? ?? 'earpiece'),
      'presence' => PresenceChanged(_map(m['presence']).map((k, v) => MapEntry(k, v == true))),
      'conferenceInvite' => ConferenceInviteReceived(ConferenceInvite.fromMap(m)),
      'conferenceStarted' => ConferenceStarted(callId: m['callId'] as String? ?? '', room: m['room'] as String? ?? ''),
      'failure' => CallFailed(code: m['code'] as String? ?? 'unknown', message: m['message'] as String? ?? ''),
      _ => CallFailed(code: 'unknown', message: 'unknown event ${m['event']}'),
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

  /// initiating | ringing | connected | onHold | reconnecting | ended. See [status].
  final String state;

  /// Why the call ended (ended, declined, missed, no-answer, busy, unreachable); set when [state] is ended.
  final String? reason;
  final CallDirection? direction;
  final Contact? peer;
  final bool? muted, held;
  const CallStateChanged({required this.callId, required this.state, this.reason, this.direction, this.peer, this.muted, this.held});

  CallStatus get status => callStatusFromWire(state);
}

class QualityUpdated extends InCallEvent {
  final CallQuality quality;
  final String? callId;
  const QualityUpdated(this.quality, {this.callId});
}

class MessageReceived extends InCallEvent {
  final Message message;
  final String peerSip;
  const MessageReceived({required this.message, required this.peerSip});
}

/// A sent message's delivery state changed (sent, delivered, read, failed).
class MessageStatusChanged extends InCallEvent {
  final String messageId;
  final MessageStatus status;
  final String? peerSip;
  const MessageStatusChanged({required this.messageId, required this.status, this.peerSip});
}

/// Call audio moved: 'earpiece', 'speaker' or 'bluetooth' (FR-CALL-04).
class AudioRouteChanged extends InCallEvent {
  final String route;
  const AudioRouteChanged(this.route);

  AudioRoute get audioRoute => audioRouteFromWire(route);
}

/// Contacts came online or went offline (sipUser to connected), while presence updates run (FR-SDK-05).
class PresenceChanged extends InCallEvent {
  final Map<String, bool> presence;
  const PresenceChanged(this.presence);
}

/// Someone invites this user into a 3-way call.
class ConferenceInviteReceived extends InCallEvent {
  final ConferenceInvite invite;
  const ConferenceInviteReceived(this.invite);
}

/// The SDK joined a 3-way call by itself (the person you were talking to moved the call there).
class ConferenceStarted extends InCallEvent {
  final String callId, room;
  const ConferenceStarted({required this.callId, required this.room});
}

class CallFailed extends InCallEvent {
  final String code, message;
  const CallFailed({required this.code, required this.message});

  InCallErrorCode get errorCode => errorCodeFromWire(code);
}
