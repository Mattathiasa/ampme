import 'package:ampme/features/host/widgets/transport_controls.dart';
import 'package:ampme/theme/app_theme.dart';
import 'package:ampme/ui/device_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.dark(),
    home: Scaffold(body: child),
  );

  testWidgets('a device reads as one item: name and status together', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(const DeviceTile(name: 'Kitchen', status: 'In sync')));
    expect(find.bySemanticsLabel(RegExp('Kitchen.*In sync', dotAll: true)), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the volume slider has a name and a spoken value', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(VolumeRow(volume: 0.5, onChanged: (_) {})));
    expect(find.bySemanticsLabel('Volume'), findsOneWidget);
    expect(find.semantics.byValue('50 percent'), findsOneWidget);
    handle.dispose();
  });
}
