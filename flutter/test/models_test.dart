import 'package:flutter_test/flutter_test.dart';
import 'package:incall_flutter/incall_flutter.dart';

void main() {
  group('InCallEvent.fromMap', () {
    test('registration', () {
      expect((InCallEvent.fromMap({'event': 'registration', 'state': 'registered'}) as RegistrationChanged).state, RegistrationState.registered);
      expect((InCallEvent.fromMap({'event': 'registration', 'state': 'weird'}) as RegistrationChanged).state, RegistrationState.offline);
    });

    test('incomingCall with and without a contact', () {
      final e = InCallEvent.fromMap({
        'event': 'incomingCall',
        'callId': 'c1',
        'from': {'name': 'vineet', 'sipUser': '1005', 'displayName': 'Vineet', 'userType': 'agent'},
      }) as IncomingCall;
      expect(e.callId, 'c1');
      expect(e.from?.sipUser, '1005');
      expect(e.from?.userType, 'agent');
      expect((InCallEvent.fromMap({'event': 'incomingCall', 'callId': 'c2'}) as IncomingCall).from, isNull);
    });

    test('callState carries reason, direction, peer, mute and hold', () {
      final e = InCallEvent.fromMap({
        'event': 'callState',
        'callId': 'c1',
        'state': 'ended',
        'reason': 'no-answer',
        'direction': 'outgoing',
        'peer': {'name': 'v', 'sipUser': '1005', 'displayName': 'V', 'userType': 'customer'},
        'muted': true,
        'held': false,
      }) as CallStateChanged;
      expect(e.status, CallStatus.ended);
      expect(e.reason, 'no-answer');
      expect(e.direction, CallDirection.outgoing);
      expect(e.peer?.sipUser, '1005');
      expect(e.muted, isTrue);
      expect(e.held, isFalse);
      // The old minimal shape still decodes.
      final old = InCallEvent.fromMap({'event': 'callState', 'callId': 'c', 'state': 'onHold'}) as CallStateChanged;
      expect(old.status, CallStatus.onHold);
      expect(old.direction, isNull);
    });

    test('quality, with nulls and ints for doubles', () {
      final e = InCallEvent.fromMap({
        'event': 'quality',
        'callId': 'c1',
        'quality': {'rttMs': 120, 'jitterMs': null, 'lossPct': 1, 'mos': null},
      }) as QualityUpdated;
      expect(e.callId, 'c1');
      expect(e.quality.rttMs, 120);
      expect(e.quality.jitterMs, isNull);
      expect(e.quality.lossPct, 1.0);
    });

    test('message and messageStatus', () {
      final m = InCallEvent.fromMap({
        'event': 'message',
        'peerSip': '1005',
        'message': {'id': 'x', 'from': 'peer', 'location': {'lat': 1, 'lng': 2, 'label': 'Pin'}, 'status': 'delivered'},
      }) as MessageReceived;
      expect(m.peerSip, '1005');
      expect(m.message.location?.lat, 1.0);
      final s = InCallEvent.fromMap({'event': 'messageStatus', 'messageId': 'x', 'status': 'read'}) as MessageStatusChanged;
      expect(s.status, MessageStatus.read);
    });

    test('presence, conference and failure', () {
      final p = InCallEvent.fromMap({'event': 'presence', 'presence': {'1005': true, '1006': false}}) as PresenceChanged;
      expect(p.presence, {'1005': true, '1006': false});
      final inv = InCallEvent.fromMap({
        'event': 'conferenceInvite',
        'room': 'r1',
        'from': {'name': 'a', 'sipUser': '1002', 'displayName': 'A', 'userType': 'agent'},
        'with': ['1003'],
      }) as ConferenceInviteReceived;
      expect(inv.invite.room, 'r1');
      expect(inv.invite.withSipUsers, ['1003']);
      final st = InCallEvent.fromMap({'event': 'conferenceStarted', 'callId': 'c9', 'room': 'r1'}) as ConferenceStarted;
      expect(st.callId, 'c9');
      final f = InCallEvent.fromMap({'event': 'failure', 'code': 'peerUnreachable', 'message': 'gone'}) as CallFailed;
      expect(f.errorCode, InCallErrorCode.peerUnreachable);
    });

    test('unknown events become a CallFailed instead of throwing', () {
      expect(InCallEvent.fromMap({'event': 'fromTheFuture'}), isA<CallFailed>());
    });
  });

  group('CallQuality.bars', () {
    test('MOS wins when present', () {
      expect(const CallQuality(mos: 4.3, rttMs: 900).bars, 3);
      expect(const CallQuality(mos: 3.6).bars, 2);
      expect(const CallQuality(mos: 2.1).bars, 1);
    });
    test('falls back to RTT and loss', () {
      expect(const CallQuality().bars, 0);
      expect(const CallQuality(rttMs: 80, lossPct: 0.5).bars, 3);
      expect(const CallQuality(rttMs: 300, lossPct: 1).bars, 2);
      expect(const CallQuality(rttMs: 100, lossPct: 9).bars, 1);
    });
  });

  test('AudioRoutes de-duplicates and defaults', () {
    final r = AudioRoutes.fromMap({'available': ['speaker', 'speaker', 'earpiece'], 'current': 'nope'});
    expect(r.available, [AudioRoute.speaker, AudioRoute.earpiece]);
    expect(r.current, AudioRoute.earpiece);
  });
}
