import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/pages/local_section.dart';
import 'package:rapp/pages/permissions_panel.dart';
import 'package:rapp/permissions.dart';
import 'package:rapp/service_client.dart';

import 'service_client_test.dart' show FakeService, until;
import 'ui/helpers.dart';

const resetLabel = '设置里已经打开了还是 ✗？重置授权记录';
const manualSteps = '辅助功能的旧记录要在系统设置里删：选中 rapp，点「−」，再重新添加。';

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

  testWidgets('reset button under each missing row needs two taps', (tester) async {
    var resets = 0;
    Widget panel(Map<String, dynamic> perms, {bool withReset = true}) => wrap(SizedBox(
          width: 600,
          child: PermissionsPanel(
            permissions: perms,
            onOpenSettings: (_) async {},
            onReset: withReset ? () async => resets++ : null,
          ),
        ));
    await tester.pumpWidget(panel(const {'screen_recording': false, 'accessibility': true}));
    expect(find.text(resetLabel), findsOneWidget);
    await tester.tap(find.text(resetLabel));
    await tester.pump();
    expect(resets, 0);
    await tester.tap(find.text('再点一次确认'));
    await tester.pump();
    expect(resets, 1);

    await tester.pumpWidget(panel(const {'screen_recording': false, 'accessibility': false}));
    expect(find.text(resetLabel), findsNWidgets(2));
    await tester.pumpWidget(panel(const {'screen_recording': false, 'accessibility': true}, withReset: false));
    expect(find.text(resetLabel), findsNothing);
    await tester.pumpWidget(panel(const {'screen_recording': true, 'accessibility': true}));
    expect(find.text(resetLabel), findsNothing);
  });

  group('LocalSection', () {
    late Directory tmp;
    late FakeService svc;
    late ServiceMonitor m;
    late List<Permission> opened;
    late int quits;
    late bool confirm;
    late int confirms;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('rapp-local');
      opened = [];
      quits = 0;
      confirms = 0;
      confirm = true;
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    File marker() => File('${tmp.path}${Platform.pathSeparator}permission-guide-shown');

    /// Starts the fake service and the section; the first-run guide is already marked shown.
    Future<void> pump(WidgetTester tester, {UpdateHooks? hooks, bool useHooks = true}) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      if (!marker().existsSync()) marker().writeAsStringSync('old');
      await tester.runAsync(() async {
        await svc.start();
        m = ServiceMonitor(readToken: () async => 'tok', port: svc.port, retry: const Duration(milliseconds: 50));
        m.start();
        await until(() => m.status != null);
      });
      addTearDown(() async {
        m.dispose();
        await tester.runAsync(svc.stop);
      });
      await tester.pumpWidget(wrap(SingleChildScrollView(
        child: LocalSection(
          platform: TargetPlatform.macOS,
          monitor: m,
          control: null,
          configDir: tmp.path,
          openSettings: (p) async => opened.add(p),
          hooks: useHooks
              ? hooks ??
                  UpdateHooks(
                    confirmQuit: () async {
                      confirms++;
                      return confirm;
                    },
                    quitNow: () async => quits++,
                  )
              : null,
        ),
      )));
      await tester.pump();
    }

    /// Lets socket replies arrive (real time) and what they complete run (pumps), until [cond].
    Future<void> settle(WidgetTester tester, bool Function() cond) async {
      for (var i = 0; i < 300 && !cond(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(cond(), isTrue);
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
    }

    const ready = {'current': '0.4.1', 'state': 'ready', 'latest': '0.5.0', 'auto_update': true};

    testWidgets('the update section sits under the permissions', (tester) async {
      svc = FakeService('tok')..update = {'current': '0.4.1', 'state': 'up_to_date', 'latest': '0.4.1'};
      await pump(tester);
      expect(find.text('版本与升级'), findsOneWidget);
      expect(find.text('当前 0.4.1 · 已是最新'), findsOneWidget);
      expect(tester.getTopLeft(find.text('版本与升级')).dy,
          greaterThan(tester.getTopLeft(find.text(Permission.accessibility.purpose)).dy));
    });

    testWidgets('an older service without update shows no update section', (tester) async {
      svc = FakeService('tok');
      await pump(tester);
      expect(find.text('版本与升级'), findsNothing);
    });

    testWidgets('reset failure shows the manual steps', (tester) async {
      svc = FakeService('tok')
        ..perms = {'screen_recording': false, 'accessibility': true}
        ..replies['permissions_reset'] = {
          'ok': true,
          'screen_recording_reset': true,
          'accessibility_reset': false,
          'permissions': {'screen_recording': false, 'accessibility': true},
        };
      await pump(tester);
      expect(find.text(manualSteps), findsNothing);
      await tester.tap(find.text(resetLabel));
      await tester.pump();
      await tester.tap(find.text('再点一次确认'));
      await tester.pump();
      await settle(tester, () => svc.received.any((r) => r['cmd'] == 'permissions_reset'));
      expect(find.text(manualSteps), findsOneWidget);
      final open = find.byKey(const Key('reset-open-accessibility'));
      expect(find.descendant(of: open, matching: find.text('打开系统设置')), findsOneWidget);
      await tester.tap(open);
      await settle(tester, () => opened.isNotEmpty);
      expect(opened, [Permission.accessibility]);
    });

    testWidgets('manual steps stay while accessibility stays unchecked', (tester) async {
      svc = FakeService('tok')
        ..perms = {'screen_recording': true, 'accessibility': false}
        ..replies['permissions_reset'] = {
          'ok': true,
          'screen_recording_reset': true,
          'accessibility_reset': false,
          'permissions': {'screen_recording': true, 'accessibility': false},
        };
      await pump(tester);
      await tester.tap(find.text(resetLabel));
      await tester.pump();
      await tester.tap(find.text('再点一次确认'));
      await tester.pump();
      await settle(tester, () => svc.received.any((r) => r['cmd'] == 'permissions_reset'));
      expect(find.text(manualSteps), findsOneWidget);
      // A status poll while accessibility still reads ✗ must not drop the hint.
      await tester.runAsync(() => m.checkPermissions());
      await tester.pump(const Duration(seconds: 4));
      expect(find.text(manualSteps), findsOneWidget);
      // Once it reads ✓ the hint goes.
      svc.perms = {'screen_recording': true, 'accessibility': true};
      await tester.runAsync(() => m.checkPermissions());
      await tester.pump(const Duration(seconds: 4));
      expect(find.text(manualSteps), findsNothing);
    });

    testWidgets('a working reset shows no manual steps', (tester) async {
      svc = FakeService('tok')
        ..perms = {'screen_recording': false, 'accessibility': true}
        ..replies['permissions_reset'] = {'ok': true, 'screen_recording_reset': true, 'accessibility_reset': true};
      await pump(tester);
      await tester.tap(find.text(resetLabel));
      await tester.pump();
      await tester.tap(find.text('再点一次确认'));
      await tester.pump();
      await settle(tester, () => svc.received.any((r) => r['cmd'] == 'permissions_reset'));
      expect(find.text(manualSteps), findsNothing);
    });

    testWidgets('lost after update shows the guide even if already shown', (tester) async {
      svc = FakeService('tok')
        ..perms = {'screen_recording': false, 'accessibility': false}
        ..lostAfterUpdate = true;
      await pump(tester);
      await tester.pump();
      expect(find.byType(PermissionGuideDialog), findsOneWidget);
      expect(find.descendant(of: find.byType(PermissionGuideDialog), matching: find.text(resetLabel)),
          findsNWidgets(2));
      expect(marker().readAsStringSync(), 'old');
    });

    testWidgets('lost flag that arrives later still shows the guide once', (tester) async {
      svc = FakeService('tok')..perms = {'screen_recording': false, 'accessibility': false};
      await pump(tester);
      await tester.pump();
      expect(find.byType(PermissionGuideDialog), findsNothing);
      svc.lostAfterUpdate = true;
      svc.pushChanged();
      await settle(tester, () => m.status!.permissionsLostAfterUpdate);
      await tester.pump();
      expect(find.byType(PermissionGuideDialog), findsOneWidget);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      svc.pushChanged();
      await settle(tester, () => svc.received.where((r) => r['cmd'] == 'status').length >= 3);
      await tester.pump();
      expect(find.byType(PermissionGuideDialog), findsNothing);
      expect(marker().readAsStringSync(), 'old');
    });

    testWidgets('apply asks to quit then quits', (tester) async {
      svc = FakeService('tok')..update = ready;
      await pump(tester);
      await tester.tap(find.text('立即升级'));
      await settle(tester, () => quits > 0);
      expect(confirms, 1);
      expect(svc.received.where((r) => r['cmd'] == 'update_apply').single,
          {'cmd': 'update_apply', 'confirm_signature_change': false});
      expect(quits, 1);
    });

    testWidgets('apply that is not confirmed sends nothing', (tester) async {
      svc = FakeService('tok')..update = ready;
      confirm = false;
      await pump(tester);
      await tester.tap(find.text('立即升级'));
      await settle(tester, () => confirms > 0);
      expect(svc.received.where((r) => r['cmd'] == 'update_apply'), isEmpty);
      expect(quits, 0);
    });

    testWidgets('without hooks apply only sends update_apply', (tester) async {
      svc = FakeService('tok')..update = ready;
      await pump(tester, useHooks: false);
      await tester.tap(find.text('立即升级'));
      await settle(tester, () => svc.received.any((r) => r['cmd'] == 'update_apply'));
      expect(quits, 0);
    });

    testWidgets('apply error stays in the section', (tester) async {
      svc = FakeService('tok')
        ..update = ready
        ..replies['update_apply'] = {'ok': false, 'error': '有 1 个远程会话在用这台电脑'};
      await pump(tester);
      await tester.tap(find.text('立即升级'));
      await settle(tester, () => svc.received.any((r) => r['cmd'] == 'update_apply'));
      expect(find.text('有 1 个远程会话在用这台电脑'), findsOneWidget);
      expect(quits, 0);
    });

    testWidgets('rollback asks to quit then quits', (tester) async {
      svc = FakeService('tok')..update = {'current': '0.5.0', 'state': 'up_to_date', 'can_rollback': true};
      await pump(tester);
      await tester.tap(find.text('回到上一版'));
      await tester.pump();
      await tester.tap(find.text('再点一次确认'));
      await settle(tester, () => quits > 0);
      expect(confirms, 1);
      expect(svc.received.where((r) => r['cmd'] == 'update_rollback'), hasLength(1));
    });
  });
}
