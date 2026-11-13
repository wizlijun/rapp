import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/pages/data_section.dart';
import 'package:rapp/data_dir.dart';
import 'package:rapp/data_relocate.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import 'fakes.dart';
import 'ui/helpers.dart';

void main() {
  test('sync status words', () {
    expect(syncStatusText(null), '还没有版本记录');
    expect(syncStatusText({'git': 'missing'}), '没装 git，文字没有版本记录');
    expect(syncStatusText({'git': 'local'}), '只在本机');
    expect(
        syncStatusText({'git': 'synced', 'last_sync': '2026-11-13T09:05:00.000Z'},
            parse: (s) => DateTime.parse(s).toLocal()),
        startsWith('已同步 '));
    expect(syncStatusText({'git': 'conflict'}), '同步有冲突，需要手工处理');
    expect(syncStatusText({'git': 'error', 'error': 'push refused'}), '同步没成功：push refused');
    expect(syncStatusText({'git': 'weird'}), '还没有版本记录');
  });

  test('readSyncStatus is null on any problem', () {
    final tmp = Directory.systemTemp.createTempSync('rapp-sync');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final d = DataDir(tmp.path);
    expect(readSyncStatus(d), isNull);
    Directory(d.localDir).createSync();
    File('${d.localDir}/sync.json').writeAsStringSync('nope');
    expect(readSyncStatus(d), isNull);
    File('${d.localDir}/sync.json').writeAsStringSync('{"git":"local"}');
    expect(readSyncStatus(d), {'git': 'local'});
  });

  testWidgets('shows the path and the status; 打开数据目录 opens the root', (t) async {
    final tmp = Directory.systemTemp.createTempSync('rapp-data-section');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final d = DataDir(tmp.path);
    Directory(d.localDir).createSync(recursive: true);
    File('${d.localDir}/sync.json').writeAsStringSync('{"git":"local"}');
    final opened = <String>[];
    await t.pumpWidget(wrap(SizedBox(
        width: 600, child: DataSection(data: d, openFolder: (p) async => opened.add(p)))));
    expect(find.text(tmp.path), findsOneWidget);
    expect(find.text('只在本机'), findsOneWidget);
    await t.tap(find.text('打开数据目录'));
    await t.pump();
    expect(opened, [tmp.path]);
    expect(find.text('更改位置…'), findsNothing);
    // The periodic re-read picks up a new sync.json.
    File('${d.localDir}/sync.json').writeAsStringSync('{"git":"conflict"}');
    await t.pump(const Duration(seconds: 10));
    expect(find.text('同步有冲突，需要手工处理'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  group('relocate', () {
    late Directory tmp;
    late String from, cfg, pointer;
    late Map<String, String> env;
    late MainState state;
    late List<String> restarts, homes;
    late DataRelocator relocator;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('rapp-reloc-ui');
      from = '${tmp.path}/home/rapp-old';
      cfg = '${tmp.path}/home/.config';
      env = {'HOME': '${tmp.path}/home', 'XDG_CONFIG_HOME': cfg};
      prepareDataDir(from, '${tmp.path}/none');
      pointer = pointerFile(env, 'linux');
      state = MainState(hub: HubClient(FakeTransport()), data: DataDir(from), prefs: UiPrefs());
      restarts = [];
      homes = [];
      relocator = DataRelocator(
        env: env,
        os: 'linux',
        restartService: () async {
          restarts.add('r');
          return null;
        },
        setHubHome: (d) async => homes.add(d),
        state: state,
      );
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<void> pumpIt(WidgetTester t, {Map<String, String>? e, Future<String?> Function()? pick}) async {
      final r = e == null ? relocator : DataRelocator(env: e, os: 'linux', restartService: relocator.restartService, setHubHome: relocator.setHubHome, state: state);
      await t.pumpWidget(wrap(SizedBox(
          width: 600, child: DataSection(data: state.data, relocate: r, pickFolder: pick, openFolder: (_) async {}))));
    }

    testWidgets('adopting says so before doing anything', (t) async {
      final to = '${tmp.path}/theirs';
      prepareDataDir(to, '${tmp.path}/none');
      await pumpIt(t, pick: () async => to);
      await t.tap(find.text('更改位置…'));
      await t.pumpAndSettle();
      expect(find.text('改数据目录的位置？'), findsOneWidget);
      expect(find.textContaining('会直接用它'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(restarts, isEmpty);
      expect(File(pointer).existsSync(), isFalse);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a change restarts the service, moves the hub and the state', (t) async {
      final to = '${tmp.path}/new';
      await pumpIt(t, pick: () async => to);
      await t.tap(find.text('更改位置…'));
      await t.pumpAndSettle();
      expect(find.textContaining('会把 $from 里的数据复制到 $to'), findsOneWidget);
      await t.tap(find.text('改'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
      await t.pumpAndSettle();
      expect(restarts.length, 1);
      expect(homes, ['$to/local']);
      expect(state.data.root, to);
      expect(File(pointer).readAsStringSync(), '$to\n');
      expect(find.text('数据目录已改到 $to，服务已重启'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('RAPP_HOME set: no buttons, a note', (t) async {
      await pumpIt(t, e: {...env, 'RAPP_HOME': from});
      expect(find.text('更改位置…'), findsNothing);
      expect(find.text('改回默认'), findsNothing);
      expect(find.text('位置由环境变量 RAPP_HOME 决定'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('改回默认 only shows away from the default', (t) async {
      await pumpIt(t);
      expect(find.text('改回默认'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      state.data = DataDir(defaultDataRoot(env, 'linux'));
      await pumpIt(t);
      expect(find.text('改回默认'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  });
}
