import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incall_flutter/incall_flutter.dart';

/// A fake native side for the incall_flutter channels: records method calls, answers them from [responses]
/// (a value, or a function of the call; throw a PlatformException to fail), and pushes events.
class FakeNative {
  FakeNative() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      final r = responses[call.method];
      if (r is Function) return (r as dynamic)(call);
      return r;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (args, sink) {
        _sink = sink;
      }, onCancel: (args) {
        _sink = null;
      }),
    );
    InCall.instance.debugReset();
  }

  static const method = MethodChannel('incall_flutter');
  static const events = EventChannel('incall_flutter/events');

  final calls = <MethodCall>[];
  final responses = <String, Object?>{};
  MockStreamHandlerEventSink? _sink;

  bool get listening => _sink != null;

  List<String> get methods => calls.map((c) => c.method).toList();

  MethodCall last(String name) => calls.lastWhere((c) => c.method == name);

  /// Send one event map, as the native bridge would.
  Future<void> emit(Map<String, Object?> event) async {
    _sink!.success(event);
    await pumpEventQueue();
  }

  /// Ask Dart for a token, as the native SDK does, and return the reply.
  Future<Object?> requestToken() async {
    const codec = StandardMethodCodec();
    final reply = await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage('incall_flutter', codec.encodeMethodCall(const MethodCall('getToken')), (_) {});
    return reply == null ? null : codec.decodeEnvelope(reply);
  }

  void dispose() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockStreamHandler(events, null);
    InCall.instance.debugReset();
  }
}

Map<String, Object?> contactMap(String sip, [String? name]) =>
    {'name': sip, 'sipUser': sip, 'displayName': name ?? sip, 'userType': 'customer'};
