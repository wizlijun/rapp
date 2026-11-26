import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/pages/global_sections.dart';
import 'package:rapp/pages/state_section.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/state/state_config.dart';
import 'package:rapp/state/state_sync.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';

/// Saves the config like the real one but opens no connection.
class _Sync extends FakeStateSync {
  _Sync(super.localDir);
  int saves = 0;
  @override
  Future<void> setConfig(StateConfig c) {
    saves++;
    config = c;
    c.save(localDir);
    return Future.value();
  }
}

void main() {
  late Directory dir;
  late _Sync sync;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('state_section');
    sync = _Sync(dir.path);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> pump(WidgetTester t) => t.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: StateSection(sync: sync)))));

  testWidgets('the three choices save to local/state.json', (t) async {
    await pump(t);
    expect(find.text('状态服务'), findsOneWidget);
    expect(find.text('自动'), findsOneWidget);
    expect(find.text('关'), findsOneWidget);

    await t.tap(find.text('关'));
    await t.pump();
    expect(StateConfig.load(dir.path).mode, StateMode.off);

    await t.tap(find.text('手填地址'));
    await t.pump();
    await t.enterText(find.byType(TextField), 'ftp://x');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(find.text('地址要以 http:// 或 https:// 开头'), findsOneWidget);
    expect(StateConfig.load(dir.path).mode, StateMode.off);

    await t.enterText(find.byType(TextField), 'http://h:8102');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(find.text('地址要以 http:// 或 https:// 开头'), findsNothing);
    final c = StateConfig.load(dir.path);
    expect([c.mode, c.url], [StateMode.manual, 'http://h:8102']);

    await t.tap(find.text('自动'));
    await t.pump();
    expect(StateConfig.load(dir.path).mode, StateMode.auto);
  });

  testWidgets('leaving the address field saves it as Enter does', (t) async {
    await pump(t);
    await t.tap(find.text('手填地址'));
    await t.pump();
    await t.enterText(find.byType(TextField), 'ftp://x');
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pump();
    expect(find.text('地址要以 http:// 或 https:// 开头'), findsOneWidget);
    expect(StateConfig.load(dir.path).mode, StateMode.auto);

    await t.tap(find.byType(TextField));
    await t.enterText(find.byType(TextField), 'http://h:8102');
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pump();
    expect(find.text('地址要以 http:// 或 https:// 开头'), findsNothing);
    final c = StateConfig.load(dir.path);
    expect([c.mode, c.url], [StateMode.manual, 'http://h:8102']);
    final saves = sync.saves;

    // Enter, then leaving the field: one save, not two.
    await t.tap(find.byType(TextField));
    await t.enterText(find.byType(TextField), 'http://h:9');
    await t.testTextInput.receiveAction(TextInputAction.done);
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pump();
    expect(sync.saves, saves + 1);
    expect(StateConfig.load(dir.path).url, 'http://h:9');
  });

  testWidgets('the address field starts with the saved address', (t) async {
    sync.config = const StateConfig(StateMode.manual, url: 'http://h:1');
    await pump(t);
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, 'http://h:1');
  });

  testWidgets('the status line follows the sync', (t) async {
    await pump(t);
    final words = {
      StateStatus.unreachable: '连不上',
      StateStatus.none: '没找到状态服务',
      StateStatus.off: '已关',
      StateStatus.connecting: '连接中…',
    };
    for (final e in words.entries) {
      sync.status = e.key;
      sync.notifyListeners();
      await t.pump();
      expect(find.text(e.value), findsOneWidget, reason: e.key.name);
    }
    sync.status = StateStatus.connected;
    sync.url = Uri.parse('http://localhost:28003');
    sync.notifyListeners();
    await t.pump();
    expect(find.text('已连上 http://localhost:28003'), findsOneWidget);
  });

  testWidgets('GlobalSections on Linux shows LinuxUpdateSection, StateSection and 0600 state.json', (t) async {
    final monitor = ServiceMonitor(readToken: () async => null);
    addTearDown(monitor.dispose);
    await t.pumpWidget(MaterialApp(
      theme: themeDataFor(RappTheme.matrix, platform: TargetPlatform.linux),
      home: Scaffold(
        body: SingleChildScrollView(
          child: GlobalSections(
            monitor: monitor,
            data: DataDir(dir.path),
            stateSync: sync,
            platform: TargetPlatform.linux,
            openPage: (_) async {},
          ),
        ),
      ),
    ));
    expect(find.text('版本与升级'), findsOneWidget);
    expect(find.text('状态服务'), findsOneWidget);
    expect(find.text('数据目录'), findsOneWidget);
    await t.tap(find.text('关'));
    await t.pump();
    final mode = File('${dir.path}/state.json').statSync().mode & 0x1ff;
    expect(mode, 0x180);
  });
}
