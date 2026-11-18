import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incall_flutter/incall_flutter.dart';

import 'test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeNative native;
  final incall = InCall.instance;

  setUp(() => native = FakeNative());
  tearDown(() => native.dispose());

  group('start', () {
    test('passes options to native and answers token requests from the provider', () async {
      var asked = 0;
      await incall.start(baseUrl: 'https://callio.example.com', tokenProvider: () async => 'tok-${++asked}', forceRelay: true);
      final start = native.last('start');
      expect(start.arguments, {
        'baseUrl': 'https://callio.example.com',
        'forceRelay': true,
        'disconnectInBackground': true,
        'nativeCallUi': true,
        'allowInsecureTransport': false,
      });
      expect(await native.requestToken(), 'tok-1');
      expect(await native.requestToken(), 'tok-2');
    });

    test('a throwing token provider answers null (native reports tokenExpired)', () async {
      await incall.start(baseUrl: 'https://x.test', tokenProvider: () async => throw Exception('backend down'));
      expect(await native.requestToken(), isNull);
    });

    test('rejects a non-http base URL without calling native', () async {
      expect(() => incall.start(baseUrl: 'callio.example.com', tokenProvider: () async => 't'), throwsArgumentError);
      expect(native.calls, isEmpty);
    });

    test('requires https unless allowInsecureTransport is set', () async {
      expect(() => incall.start(baseUrl: 'http://10.0.2.2:8080', tokenProvider: () async => 't'), throwsArgumentError);
      expect(() => incall.start(baseUrl: 'ftp://x.test', tokenProvider: () async => 't', allowInsecureTransport: true),
          throwsArgumentError);
      expect(native.calls, isEmpty);
      await incall.start(baseUrl: 'http://10.0.2.2:8080', tokenProvider: () async => 't', allowInsecureTransport: true);
      expect(native.last('start').arguments['allowInsecureTransport'], true);
    });

    test('native failures become InCallException with a stable code', () async {
      native.responses['start'] = (MethodCall _) => throw PlatformException(code: 'tokenExpired', message: 'token expired');
      await expectLater(
        incall.start(baseUrl: 'https://x.test', tokenProvider: () async => 't'),
        throwsA(isA<InCallException>().having((e) => e.code, 'code', InCallErrorCode.tokenExpired)),
      );
    });

    test('unknown native codes map to unknown and keep the raw code', () async {
      native.responses['dial'] = (MethodCall _) => throw PlatformException(code: 'SomethingNew', message: 'boom');
      await expectLater(
        incall.dial('1005'),
        throwsA(isA<InCallException>()
            .having((e) => e.code, 'code', InCallErrorCode.unknown)
            .having((e) => e.rawCode, 'rawCode', 'SomethingNew')),
      );
    });
  });

  group('calls', () {
    test('dial returns the call and tracks it as current', () async {
      native.responses['dial'] = 'call-1';
      final call = await incall.dial('1005');
      expect(native.last('dial').arguments, {'sipUser': '1005'});
      expect(call.id, 'call-1');
      expect(call.peerSipUser, '1005');
      expect(call.direction, CallDirection.outgoing);
      expect(incall.currentCall?.id, 'call-1');
    });

    test('dial rejects an empty target', () {
      expect(() => incall.dial('  '), throwsArgumentError);
    });

    test('call controls map to their native methods', () async {
      await incall.answer();
      await incall.decline();
      await incall.cancel();
      await incall.hangup();
      await incall.setMuted(true);
      await incall.setHold(false);
      await incall.sendDtmf('5');
      await incall.setAudioRoute('speaker');
      await incall.transfer('1007');
      expect(native.methods, ['answer', 'decline', 'cancel', 'hangup', 'setMuted', 'setHold', 'sendDtmf', 'setAudioRoute', 'transfer']);
      expect(native.last('setMuted').arguments, {'muted': true});
      expect(native.last('setHold').arguments, {'held': false});
      expect(native.last('sendDtmf').arguments, {'tone': '5'});
      expect(native.last('setAudioRoute').arguments, {'route': 'speaker'});
      expect(native.last('transfer').arguments, {'sipUser': '1007'});
    });

    test('validates DTMF tones and audio routes', () {
      expect(() => incall.sendDtmf('55'), throwsArgumentError);
      expect(() => incall.sendDtmf('x'), throwsArgumentError);
      expect(() => incall.setAudioRoute('headphones'), throwsArgumentError);
      expect(native.calls, isEmpty);
    });

    test('audioRoutes decodes available and current', () async {
      native.responses['audioRoutes'] = {'available': ['earpiece', 'speaker', 'bluetooth'], 'current': 'bluetooth'};
      final r = await incall.audioRoutes();
      expect(r.available, [AudioRoute.earpiece, AudioRoute.speaker, AudioRoute.bluetooth]);
      expect(r.current, AudioRoute.bluetooth);
    });

    test('joinConference sends the room and returns the call', () async {
      native.responses['joinConference'] = 'conf-call';
      final c = await incall.joinConference('room-9');
      expect(native.last('joinConference').arguments, {'room': 'room-9'});
      expect(c.id, 'conf-call');
    });
  });

  group('chat', () {
    test('sendText and sendLocation return the message id', () async {
      native.responses['sendMessage'] = 'm-1';
      expect(await incall.sendText('1005', 'hi'), 'm-1');
      expect(native.last('sendMessage').arguments, {'to': '1005', 'text': 'hi'});
      await incall.sendLocation('1005', const SharedLocation(lat: 24.7, lng: 46.6, label: 'Office'));
      expect(native.last('sendMessage').arguments, {
        'to': '1005',
        'location': {'lat': 24.7, 'lng': 46.6, 'label': 'Office'},
      });
    });

    test('sendLocation rejects impossible coordinates', () {
      expect(() => incall.sendLocation('1005', const SharedLocation(lat: 91, lng: 0)), throwsArgumentError);
    });

    test('messages decodes the native thread', () async {
      native.responses['messages'] = [
        {'id': 'a', 'from': 'peer', 'text': 'hello', 'status': 'delivered'},
        {'id': 'b', 'from': 'me', 'location': {'lat': 1.5, 'lng': 2.5, 'label': 'Here'}, 'status': 'read'},
      ];
      final m = await incall.messages('1005');
      expect(native.last('messages').arguments, {'peer': '1005'});
      expect(m.map((x) => x.id), ['a', 'b']);
      expect(m[0].from, MessageSender.peer);
      expect(m[1].location?.label, 'Here');
      expect(m[1].deliveryStatus, MessageStatus.read);
    });

    test('setTyping', () async {
      await incall.setTyping('1005', true);
      expect(native.last('setTyping').arguments, {'to': '1005', 'typing': true});
    });
  });

  group('session, history, presence, push', () {
    test('session decodes features and directory', () async {
      native.responses['session'] = {
        'tenant': 'lab',
        'user': 'akshay',
        'sipUser': '1001',
        'userType': 'agent',
        'features': {'calling': true, 'chat': false, 'location': true, 'recording': true},
        'directory': [contactMap('1005', 'Vineet')],
        'peers': [],
        'transferTargets': [],
      };
      final s = await incall.session();
      expect(s!.user, 'akshay');
      expect(s.userType, 'agent');
      expect(s.features.chat, isFalse);
      expect(s.features.recording, isTrue);
      expect(s.directory.single.displayName, 'Vineet');
    });

    test('session is null before start', () async {
      expect(await incall.session(), isNull);
    });

    test('callHistory decodes entries', () async {
      native.responses['callHistory'] = [
        {'callId': 'c1', 'peer': 'vineet', 'peerDisplayName': 'Vineet', 'peerSipUser': '1005', 'direction': 'outgoing', 'outcome': 'answered', 'durationSec': 42, 'at': '2026-11-01T10:00:00Z'},
      ];
      final h = await incall.callHistory(limit: 10);
      expect(native.last('callHistory').arguments, {'limit': 10});
      expect(h.single.direction, CallDirection.outgoing);
      expect(h.single.durationSec, 42);
      expect(h.single.peerSipUser, '1005');
    });

    test('presence', () async {
      native.responses['refreshPresence'] = {'1005': true, '1006': false};
      expect(await incall.refreshPresence(['1005', '1006']), {'1005': true, '1006': false});
      expect(native.last('refreshPresence').arguments, {'sipUsers': ['1005', '1006']});
      await incall.startPresenceUpdates(every: const Duration(seconds: 10));
      expect(native.last('startPresenceUpdates').arguments, {'everyMs': 10000});
      await incall.stopPresenceUpdates();
      expect(native.methods.last, 'stopPresenceUpdates');
    });

    test('push registration and hand-off', () async {
      await incall.registerPush('fcm-token');
      expect(native.last('registerPush').arguments, {'token': 'fcm-token'});
      await incall.unregisterPush();
      native.responses['handlePush'] = true;
      expect(await incall.handlePush({'notification': '{"type":"incoming_call"}'}), isTrue);
      expect(native.last('handlePush').arguments, {'data': {'notification': '{"type":"incoming_call"}'}});
    });

    test('requestPermissions', () async {
      native.responses['requestPermissions'] = {'microphone': true, 'notifications': false};
      expect(await incall.requestPermissions(), {'microphone': true, 'notifications': false});
    });
  });

  group('events and tracked state', () {
    test('registration and current call follow the native events', () async {
      await incall.start(baseUrl: 'https://x.test', tokenProvider: () async => 't');
      expect(native.listening, isTrue);
      final regs = <RegistrationState>[];
      final sub = incall.registrationChanges.listen(regs.add);

      await native.emit({'event': 'registration', 'state': 'connecting'});
      await native.emit({'event': 'registration', 'state': 'registered'});
      expect(incall.registrationState, RegistrationState.registered);
      expect(regs, [RegistrationState.connecting, RegistrationState.registered]);

      await native.emit({'event': 'incomingCall', 'callId': 'in-1', 'from': contactMap('1005', 'Vineet')});
      expect(incall.currentCall?.id, 'in-1');
      expect(incall.currentCall?.direction, CallDirection.incoming);
      expect(incall.currentCall?.peer?.displayName, 'Vineet');

      await native.emit({'event': 'callState', 'callId': 'in-1', 'state': 'ended', 'reason': 'missed'});
      expect(incall.currentCall, isNull);
      await sub.cancel();
    });

    test('events stream delivers typed events', () async {
      final got = <InCallEvent>[];
      final sub = incall.events.listen(got.add);
      await pumpEventQueue();
      await native.emit({'event': 'message', 'peerSip': '1005', 'message': {'id': 'm', 'from': 'peer', 'text': 'yo', 'status': 'delivered'}});
      await native.emit({'event': 'audioRoute', 'route': 'speaker'});
      expect(got[0], isA<MessageReceived>().having((e) => e.message.text, 'text', 'yo'));
      expect(got[1], isA<AudioRouteChanged>().having((e) => e.audioRoute, 'route', AudioRoute.speaker));
      await sub.cancel();
    });
  });
}
