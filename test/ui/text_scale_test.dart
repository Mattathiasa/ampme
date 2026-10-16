import 'package:ampme/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// People who raise their system font size must still be able to use every
/// screen: nothing may overflow at 2x, and the main actions stay reachable.
void main() {
  Future<void> pumpApp(WidgetTester tester, {double scale = 2.0}) async {
    tester.view.physicalSize = const Size(360 * 3, 740 * 3);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(const AmpmeApp());
  }

  testWidgets('home at 2x text', (tester) async {
    await pumpApp(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.text('Host a Session'), findsOneWidget);
    expect(find.text('Join a Session'), findsOneWidget);
  });

  testWidgets('host setup at 2x text', (tester) async {
    await pumpApp(tester);
    await tester.ensureVisible(find.text('Host a Session'));
    await tester.pump();
    await tester.tap(find.text('Host a Session'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Session name', skipOffstage: false), findsOneWidget);
  });

  testWidgets('join at 2x text', (tester) async {
    await pumpApp(tester);
    await tester.ensureVisible(find.text('Join a Session'));
    await tester.pump();
    await tester.tap(find.text('Join a Session'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Nearby sessions'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Nearby sessions'), findsOneWidget);
  });
}
