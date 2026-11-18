import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incall_flutter/incall_flutter.dart';

import 'test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeNative native;

  setUp(() {
    native = FakeNative();
    native.responses['audioRoutes'] = {'available': ['earpiece', 'speaker'], 'current': 'earpiece'};
  });
  tearDown(() => native.dispose());

  group('CallController', () {
    test('follows an outgoing call from dial to hang-up', () async {
      final c = CallController(peerSipUser: '1005');
      await pumpEventQueue();
      expect(c.status, CallStatus.initiating);
      expect(c.callId, '');

      await native.emit({'event': 'callState', 'callId': 'c1', 'state': 'ringing', 'direction': 'outgoing', 'peer': contactMap('1005', 'Vineet')});
      expect(c.callId, 'c1', reason: 'adopts the first call id it hears');
      expect(c.status, CallStatus.ringing);
      expect(c.displayName, 'Vineet');

      // Unanswered outgoing: End cancels.
      await c.end();
      expect(native.methods.last, 'cancel');

      await native.emit({'event': 'callState', 'callId': 'c1', 'state': 'connected'});
      expect(c.isConnected, isTrue);
      expect(c.connectedAt, isNotNull);

      await native.emit({'event': 'callState', 'callId': 'other', 'state': 'ended'});
      expect(c.isEnded, isFalse, reason: 'ignores other calls');

      await native.emit({'event': 'quality', 'callId': 'c1', 'quality': {'rttMs': 90, 'lossPct': 0.2}});
      expect(c.quality?.bars, 3);

      await c.end();
      expect(native.methods.last, 'hangup');

      await native.emit({'event': 'callState', 'callId': 'c1', 'state': 'ended', 'reason': 'ended'});
      expect(c.isEnded, isTrue);
      expect(c.endReason, 'ended');
      c.dispose();
    });

    test('incoming call: End declines while ringing', () async {
      final c = CallController.incoming(IncomingCall(callId: 'in', from: Contact.fromMap(contactMap('1007', 'Sara'))));
      expect(c.isRinging, isTrue);
      expect(c.displayName, 'Sara');
      await c.end();
      expect(native.methods.last, 'decline');
      c.dispose();
    });

    test('mute, hold and speaker are optimistic and roll back on failure', () async {
      final c = CallController(callId: 'c1', peerSipUser: '1005', status: CallStatus.connected);
      await pumpEventQueue();
      await c.toggleMute();
      expect(c.isMuted, isTrue);
      expect(native.last('setMuted').arguments, {'muted': true});

      await c.toggleSpeaker();
      expect(c.audioRoute, AudioRoute.speaker);
      expect(native.last('setAudioRoute').arguments, {'route': 'speaker'});
      await c.toggleSpeaker();
      expect(c.audioRoute, AudioRoute.earpiece);

      native.responses['setHold'] = (MethodCall _) => throw PlatformException(code: 'noActiveCall', message: 'no call');
      await expectLater(c.toggleHold(), throwsA(isA<InCallException>()));
      expect(c.isOnHold, isFalse, reason: 'rolled back');
      expect(c.lastError, isA<InCallException>());
      c.dispose();
    });

    test('audio route events update the controller', () async {
      final c = CallController(callId: 'c1', status: CallStatus.connected);
      await pumpEventQueue();
      await native.emit({'event': 'audioRoute', 'route': 'bluetooth'});
      expect(c.audioRoute, AudioRoute.bluetooth);
      expect(c.availableRoutes, contains(AudioRoute.bluetooth));
      c.dispose();
    });
  });

  group('ChatController', () {
    test('loads, sends with an optimistic bubble, and follows delivery status', () async {
      native.responses['messages'] = [
        {'id': 'old', 'from': 'peer', 'text': 'earlier', 'status': 'delivered'},
      ];
      native.responses['sendMessage'] = 'srv-1';
      final chat = ChatController(peerSipUser: '1005');
      await chat.load();
      expect(chat.messages.single.id, 'old');

      final sent = await chat.sendText('  hello  ');
      expect(native.last('sendMessage').arguments, {'to': '1005', 'text': 'hello'});
      expect(sent.id, 'srv-1');
      expect(chat.messages.last.status, 'sending');

      await native.emit({'event': 'messageStatus', 'messageId': 'srv-1', 'status': 'read'});
      expect(chat.messages.last.deliveryStatus, MessageStatus.read);

      await native.emit({'event': 'message', 'peerSip': '1005', 'message': {'id': 'p1', 'from': 'peer', 'text': 'hi back'}});
      await native.emit({'event': 'message', 'peerSip': '9999', 'message': {'id': 'p2', 'from': 'peer', 'text': 'not ours'}});
      await native.emit({'event': 'message', 'peerSip': '1005', 'message': {'id': 'p1', 'from': 'peer', 'text': 'duplicate'}});
      expect(chat.messages.map((m) => m.id), ['old', 'srv-1', 'p1']);
      chat.dispose();
    });

    test('a failed send marks the bubble failed', () async {
      native.responses['sendMessage'] = (MethodCall _) => throw PlatformException(code: 'notRegistered', message: 'offline');
      final chat = ChatController(peerSipUser: '1005');
      await expectLater(chat.sendText('x'), throwsA(isA<InCallException>()));
      expect(chat.messages.single.deliveryStatus, MessageStatus.failed);
      chat.dispose();
    });

    test('typing sends start once and stop after idle', () async {
      final chat = ChatController(peerSipUser: '1005', typingIdle: const Duration(milliseconds: 30));
      chat.typing();
      chat.typing();
      await pumpEventQueue();
      expect(native.calls.where((c) => c.method == 'setTyping').map((c) => c.arguments['typing']), [true]);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(native.calls.where((c) => c.method == 'setTyping').map((c) => c.arguments['typing']), [true, false]);
      chat.dispose();
    });

    test('rejects empty text', () {
      final chat = ChatController(peerSipUser: '1005');
      expect(() => chat.sendText('   '), throwsArgumentError);
      chat.dispose();
    });
  });
}
