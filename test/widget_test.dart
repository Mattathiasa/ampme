import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ampme/app.dart';

void main() {
  testWidgets('Home screen shows Host and Join actions', (WidgetTester tester) async {
    await tester.pumpWidget(const AmpmeApp());

    expect(find.text('Host a Session'), findsOneWidget);
    expect(find.text('Join a Session'), findsOneWidget);
  });

  testWidgets('Tapping Host a Session navigates to the host setup screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const AmpmeApp());

    await tester.tap(find.text('Host a Session'));
    await tester.pumpAndSettle();

    expect(find.text('Session name'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Start Session'), findsOneWidget);
  });

  testWidgets('Join screen offers a join-by-code field', (WidgetTester tester) async {
    await tester.pumpWidget(const AmpmeApp());

    await tester.tap(find.text('Join a Session'));
    // Let the page-route transition finish without pumpAndSettle (the
    // discovery scanner schedules periodic timers that never settle).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(TextField), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Join'), findsOneWidget);
    expect(find.text('Nearby sessions'), findsOneWidget);
  });
}
