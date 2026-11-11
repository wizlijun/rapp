import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/pages/permissions_panel.dart';
import 'package:rapp/permissions.dart';

void main() {
  testWidgets('each permission shows its purpose; missing ones get a settings button', (tester) async {
    final opened = <Permission>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PermissionsPanel(
          permissions: const {'screen_recording': false, 'accessibility': true},
          onOpenSettings: (p) async => opened.add(p),
        ),
      ),
    ));
    expect(find.text('屏幕录制'), findsOneWidget);
    expect(find.text(Permission.screenRecording.purpose), findsOneWidget);
    expect(find.text(Permission.accessibility.purpose), findsOneWidget);
    expect(find.text('打开系统设置'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    await tester.tap(find.text('打开系统设置'));
    await tester.pump();
    expect(opened, [Permission.screenRecording]);
  });

  test('the first-run guide is claimed once per config dir', () {
    final dir = Directory.systemTemp.createTempSync('rapp-guide');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(claimPermissionGuide(dir.path), isTrue);
    expect(claimPermissionGuide(dir.path), isFalse);
  });
}
