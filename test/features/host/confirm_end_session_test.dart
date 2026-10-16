import 'package:ampme/features/host/host_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<bool?> ask(WidgetTester tester, String tap) async {
    bool? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => answer = await confirmEndSession(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('End this session?'), findsOneWidget);
    expect(find.text('Everyone listening will be disconnected.'), findsOneWidget);
    await tester.tap(find.text(tap));
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('"End session" ends it', (tester) async {
    expect(await ask(tester, 'End session'), isTrue);
  });

  testWidgets('"Keep going" does not', (tester) async {
    expect(await ask(tester, 'Keep going'), isFalse);
  });
}
