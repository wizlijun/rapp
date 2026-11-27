import 'dart:io';

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
}
