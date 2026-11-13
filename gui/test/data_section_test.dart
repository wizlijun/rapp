import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/pages/data_section.dart';
import 'package:rapp/paths.dart';

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
}
