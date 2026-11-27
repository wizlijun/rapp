import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/quick/quick_prefs.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';

void main() {
  test('a quick.json write that failed before the app was up is still told', () {
    final tmp = Directory.systemTemp.createTempSync('quick_save_hint');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/blocker').writeAsStringSync('a file, not a folder');
    final quick = QuickPrefs.load('${tmp.path}/blocker/dev', legacy: const []);
    final s = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), quick: quick);
    addTearDown(s.dispose);
    expect(s.hint, startsWith('快捷区设置没有保存：'));
  });

  testWidgets('Linux desktop: unmovable broken quick.json and v>1 quick.json stay untouched and surface MainState hints',
      variant: TargetPlatformVariant.only(TargetPlatform.linux), (tester) async {
    await tester.runAsync(() async {
      final tmp = Directory.systemTemp.createTempSync('quick_save_hint_linux');
      addTearDown(() => tmp.deleteSync(recursive: true));

      // 1. Unreadable quick.json blocked from moving to quick.json.bad: startup hint + file preserved.
      final brokenDir = Directory('${tmp.path}/broken')..createSync();
      File('${brokenDir.path}/quick.json').writeAsStringSync('{corrupt');
      Directory('${brokenDir.path}/quick.json.bad').createSync();
      File('${brokenDir.path}/quick.json.bad/pin').writeAsStringSync('x');
      final qBroken = QuickPrefs.load(brokenDir.path, legacy: const []);
      final sBroken = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), quick: qBroken);
      addTearDown(sBroken.dispose);
      expect(sBroken.hint, '快捷区设置没有保存：快捷区设置文件读不了，也挪不开，原样留着');
      expect(File('${brokenDir.path}/quick.json').readAsStringSync(), '{corrupt');

      // 2. Newer-version quick.json (v: 2): read in memory, never overwritten on edit, surfaces refusal hint.
      final newerDir = Directory('${tmp.path}/newer')..createSync();
      final v2Body = jsonEncode({
        'v': 2,
        'stars': {'at': 9, 'data': ['k:esc']},
      });
      File('${newerDir.path}/quick.json').writeAsStringSync(v2Body);
      final qNewer = QuickPrefs.load(newerDir.path, legacy: const []);
      final sNewer = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), quick: qNewer);
      addTearDown(sNewer.dispose);
      sNewer.quick.dirOf = () => newerDir.path;
      expect(sNewer.quick.stars, ['k:esc']);
      sNewer.toggleStar('k:tab');
      expect(sNewer.quick.stars, ['k:esc', 'k:tab']);
      expect(File('${newerDir.path}/quick.json').readAsStringSync(), v2Body);
      expect(sNewer.hint, '快捷区设置没有保存：快捷区设置文件是更新的版本写的，原样留着');
    });
  });
}
