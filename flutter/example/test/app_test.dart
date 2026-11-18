import 'package:flutter_test/flutter_test.dart';
import 'package:incall_example/main.dart';

void main() {
  testWidgets('starts on the sign-in form', (tester) async {
    await tester.pumpWidget(const CallioExampleApp());
    expect(find.text('Callio example'), findsOneWidget);
    expect(find.text('Callio platform URL'), findsOneWidget);
    expect(find.text('Token backend URL'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('validates the form before signing in', (tester) async {
    await tester.pumpWidget(const CallioExampleApp());
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.text('Required'), findsOneWidget); // username
  });
}
