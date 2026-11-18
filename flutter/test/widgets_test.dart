import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incall_flutter/incall_ui.dart';

import 'test_harness.dart';

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532); // a 390 x 844 pt phone
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Widget _app(Widget home, {ThemeData? theme}) => MaterialApp(theme: theme ?? CallioTheme.light(), darkTheme: CallioTheme.dark(), home: home);

void main() {
  late FakeNative native;

  setUp(() {
    native = FakeNative();
    native.responses['audioRoutes'] = {'available': ['earpiece', 'speaker'], 'current': 'earpiece'};
  });
  tearDown(() => native.dispose());

  testWidgets('InCallScreen: status, timer, controls, end', (tester) async {
    _phone(tester);
    final c = CallController(callId: 'c1', peer: Contact.fromMap(contactMap('1005', 'Vineet Rao')));
    await tester.pumpWidget(_app(InCallScreen(controller: c, onClosed: () {})));
    expect(find.text('Vineet Rao'), findsOneWidget);
    expect(find.text('VR'), findsOneWidget);
    expect(find.text('Calling'), findsOneWidget);

    await tester.runAsync(() => native.emit({'event': 'callState', 'callId': 'c1', 'state': 'connected'}));
    await tester.pump();
    expect(find.text('00:00'), findsOneWidget);

    await tester.tap(find.text('Mute'));
    await tester.pump();
    expect(native.last('setMuted').arguments, {'muted': true});
    expect(find.text('Unmute'), findsOneWidget);

    await tester.tap(find.text('Speaker'));
    await tester.pump();
    expect(native.last('setAudioRoute').arguments, {'route': 'speaker'});

    await tester.tap(find.text('Hold'));
    await tester.pump();
    expect(native.last('setHold').arguments, {'held': true});

    await tester.tap(find.text('Keypad'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7'));
    await tester.pump();
    expect(native.last('sendDtmf').arguments, {'tone': '7'});
    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('End'));
    await tester.pump();
    expect(native.methods.last, 'hangup');

    await tester.runAsync(() => native.emit({'event': 'callState', 'callId': 'c1', 'state': 'ended', 'reason': 'busy'}));
    await tester.pump();
    expect(find.text('Busy'), findsWidgets);
    await tester.pump(const Duration(seconds: 2)); // close timer
    c.dispose();
  });

  testWidgets('InCallScreen with the keypad open fits a short landscape screen', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = CallController(callId: 'c1', peerSipUser: '1005', status: CallStatus.connected);
    await tester.pumpWidget(_app(InCallScreen(controller: c, onClosed: () {})));
    await tester.tap(find.text('Keypad'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('#'), findsOneWidget);
    c.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('InCallScreen renders in dark mode with a quality indicator', (tester) async {
    final c = CallController(callId: 'c1', peerSipUser: '1005', status: CallStatus.connected);
    await tester.pumpWidget(_app(InCallScreen(controller: c, onClosed: () {}), theme: CallioTheme.dark()));
    await tester.runAsync(() => native.emit({'event': 'quality', 'callId': 'c1', 'quality': {'rttMs': 500, 'lossPct': 8}}));
    await tester.pump();
    expect(find.textContaining('Poor connection'), findsOneWidget);
    c.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('IncomingCallScreen answers and reports it', (tester) async {
    _phone(tester);
    var answered = false;
    final c = CallController.incoming(IncomingCall(callId: 'in', from: Contact.fromMap(contactMap('1007', 'Sara'))));
    await tester.pumpWidget(_app(IncomingCallScreen(controller: c, onAnswered: () => answered = true)));
    expect(find.text('Sara'), findsOneWidget);
    expect(find.text('Incoming call'), findsOneWidget);
    await tester.tap(find.text('Answer'));
    await tester.pump();
    expect(native.methods, contains('answer'));
    expect(answered, isTrue);
    c.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('IncomingCallScreen closes when the caller gives up', (tester) async {
    var ended = false;
    final c = CallController.incoming(const IncomingCall(callId: 'in'));
    await tester.pumpWidget(_app(IncomingCallScreen(controller: c, onEnded: () => ended = true)));
    await tester.runAsync(() => native.emit({'event': 'callState', 'callId': 'in', 'state': 'ended', 'reason': 'missed'}));
    await tester.pump();
    expect(ended, isTrue);
    c.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ChatView sends, shows bubbles and incoming messages', (tester) async {
    native.responses['messages'] = <Object?>[];
    native.responses['sendMessage'] = 'm1';
    final chat = ChatController(peerSipUser: '1005');
    await tester.pumpWidget(_app(Scaffold(
      body: ChatView(controller: chat, locationProvider: () async => const SharedLocation(lat: 1, lng: 2, label: 'Gate 3')),
    )));
    await tester.pump();
    expect(find.text('No messages yet'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'On my way');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(native.last('sendMessage').arguments, {'to': '1005', 'text': 'On my way'});
    expect(find.text('On my way'), findsOneWidget);

    await tester.tap(find.byTooltip('Share location'));
    await tester.pump();
    expect(find.text('Gate 3'), findsOneWidget);

    await tester.runAsync(() => native.emit({'event': 'message', 'peerSip': '1005', 'message': {'id': 'p', 'from': 'peer', 'text': 'See you'}}));
    await tester.pump();
    expect(find.text('See you'), findsOneWidget);
    chat.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('CallioCallListener presents the incoming call screen', (tester) async {
    _phone(tester);
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: key,
      theme: CallioTheme.light(),
      builder: (context, child) => CallioCallListener(navigatorKey: key, child: child!),
      home: const Scaffold(body: Text('home')),
    ));
    await tester.pump();
    await tester.runAsync(() => native.emit({'event': 'incomingCall', 'callId': 'in-7', 'from': contactMap('1009', 'Omar')}));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // route transition (the ringing pulse never settles)
    expect(find.text('Omar'), findsOneWidget);
    expect(find.text('Answer'), findsOneWidget);
    await tester.runAsync(() => native.emit({'event': 'callState', 'callId': 'in-7', 'state': 'ended', 'reason': 'missed'}));
    await tester.pumpAndSettle();
    expect(find.text('Omar'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  test('theme carries the Jade palette and call style', () {
    final light = CallioTheme.light();
    expect(light.colorScheme.primary, CallioColors.jade);
    expect(light.extension<CallioCallStyle>()?.endFill, CallioColors.danger);
    final dark = CallioTheme.dark(fontFamily: 'PlusJakartaSans', displayFontFamily: 'Sora');
    expect(dark.colorScheme.primary, CallioColors.mint);
    expect(dark.textTheme.titleLarge?.fontFamily, 'Sora');
  });

  test('formatCallDuration and initials', () {
    expect(formatCallDuration(const Duration(seconds: 65)), '01:05');
    expect(formatCallDuration(const Duration(hours: 1, seconds: 5)), '1:00:05');
    expect(CallioAvatar.initials('vineet  kumar rao'), 'VR');
    expect(CallioAvatar.initials(''), '');
  });
}
