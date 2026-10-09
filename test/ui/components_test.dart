import 'package:ampme/theme/amp_tokens.dart';
import 'package:ampme/theme/app_theme.dart';
import 'package:ampme/ui/code_field.dart';
import 'package:ampme/ui/eq_visualizer.dart';
import 'package:ampme/ui/join_code_display.dart';
import 'package:ampme/ui/sync_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child, {bool reduceMotion = false}) => MaterialApp(
  theme: AppTheme.dark(),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  group('sync colours', () {
    const t = AmpTokens.dark;
    test('good within 40 ms, warn within 80 ms, bad beyond', () {
      expect(t.syncColor(0), t.syncGood);
      expect(t.syncColor(-40), t.syncGood);
      expect(t.syncColor(41), t.syncWarn);
      expect(t.syncColor(-80), t.syncWarn);
      expect(t.syncColor(81), t.syncBad);
      expect(t.syncColor(null), t.textDim);
    });

    test('ring closes as drift shrinks', () {
      expect(SyncRing.closeness(0), 1.0);
      expect(SyncRing.closeness(75), closeTo(0.5, 1e-9));
      expect(SyncRing.closeness(-500), 0.08);
      expect(SyncRing.closeness(null), 0.0);
      expect(SyncRing.signed(12), '+12');
      expect(SyncRing.signed(-7), '-7');
    });

    testWidgets('ring shows the signed drift', (tester) async {
      await tester.pumpWidget(_app(const SyncRing(driftMs: 8)));
      await tester.pumpAndSettle();
      expect(find.text('+8'), findsOneWidget);
      expect(find.text('ms'), findsOneWidget);
    });
  });

  testWidgets('join code tiles copy the code', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
      call,
    ) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    await tester.pumpWidget(_app(const JoinCodeDisplay(code: 'AMP-7KQ4ZD')));
    expect(find.text('7'), findsOneWidget);
    expect(find.text('AMP'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy code'));
    await tester.pump();
    expect(copied, 'AMP-7KQ4ZD');
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
  });

  test('code field upper-cases what is typed', () {
    final f = UpperCaseFormatter();
    final out = f.formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(text: 'amp-7kq', selection: TextSelection.collapsed(offset: 7)),
    );
    expect(out.text, 'AMP-7KQ');
    expect(out.selection.baseOffset, 7);
  });

  group('visualizer', () {
    EqVisualizerState state(WidgetTester tester) =>
        tester.state<EqVisualizerState>(find.byType(EqVisualizer));

    List<double> flat(int n) => List.filled(n, 0.9);

    testWidgets('animates a real spectrum and rests when stopped', (tester) async {
      await tester.pumpWidget(_app(EqVisualizer(playing: true, spectrum: flat)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(state(tester).isTicking, isTrue);

      await tester.pumpWidget(_app(const EqVisualizer(playing: false)));
      // Bars fall back down, then the timer stops by itself.
      expect(state(tester).isTicking, isTrue);
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(state(tester).isTicking, isFalse);
    });

    testWidgets('holds still while playing without real samples', (tester) async {
      // A synthetic animation on a listener measurably loosens its sync.
      await tester.pumpWidget(_app(const EqVisualizer(playing: true)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(state(tester).isTicking, isFalse);
    });

    testWidgets('drifts gently when idle', (tester) async {
      await tester.pumpWidget(_app(const EqVisualizer(playing: false, idle: true)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(state(tester).isTicking, isTrue);
    });

    testWidgets('never ticks with reduced motion', (tester) async {
      await tester.pumpWidget(
        _app(const EqVisualizer(playing: true, idle: true), reduceMotion: true),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(state(tester).isTicking, isFalse);
    });

    testWidgets('follows a real spectrum when given one', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _app(
          EqVisualizer(
            playing: true,
            bars: 4,
            spectrum: (n) {
              calls++;
              return List.filled(n, 0.9);
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(calls, greaterThan(0));
    });
  });
}
