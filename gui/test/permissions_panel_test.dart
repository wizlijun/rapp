import 'dart:async';
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

  Widget guide(Map<String, dynamic>? perms, {Future<void> Function()? onRestart}) => MaterialApp(
        home: Scaffold(
          body: PermissionGuideDialog(permissions: perms, onOpenSettings: (_) async {}, onRestart: onRestart),
        ),
      );

  FilledButton done(WidgetTester tester) => tester.widget<FilledButton>(find.widgetWithText(FilledButton, '完成'));

  testWidgets('guide: while something is missing, 完成 is off and 重启服务 is right there', (tester) async {
    var restarts = 0;
    await tester.pumpWidget(guide(const {'screen_recording': false, 'accessibility': true}, onRestart: () async => restarts++));
    expect(done(tester).onPressed, isNull);
    expect(find.textContaining('点「重启服务」'), findsOneWidget);
    await tester.tap(find.text('重启服务'));
    await tester.pump();
    expect(restarts, 1);
  });

  testWidgets('guide: all granted enables 完成 and hides 重启服务', (tester) async {
    await tester.pumpWidget(guide(const {'screen_recording': true, 'accessibility': true}, onRestart: () async {}));
    expect(done(tester).onPressed, isNotNull);
    expect(find.text('重启服务'), findsNothing);
  });

  test('promptThenOpen opens the pane even when the prompt hangs or fails', () async {
    var opened = 0;
    await promptThenOpen(() => Completer<void>().future, () async => opened++, wait: const Duration(milliseconds: 10));
    await promptThenOpen(() async => throw Exception('no service'), () async => opened++);
    expect(opened, 2);
  });

  test('promptThenOpen waits for a quick prompt before opening', () async {
    final order = <String>[];
    await promptThenOpen(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      order.add('prompt');
    }, () async => order.add('open'));
    expect(order, ['prompt', 'open']);
  });
}
