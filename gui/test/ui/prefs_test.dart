import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rapp_prefs'));
  tearDown(() {
    try {
      Process.runSync('chmod', ['-R', '700', tmp.path]);
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('defaults when file missing', () {
    final p = UiPrefs.load(tmp.path);
    expect(p.theme, RappTheme.matrix);
    expect(p.startFullscreen, isTrue);
  });
  test('round-trips theme and start_fullscreen', () {
    UiPrefs(theme: RappTheme.westworld, startFullscreen: false).save(tmp.path);
    final p = UiPrefs.load(tmp.path);
    expect(p.theme, RappTheme.westworld);
    expect(p.startFullscreen, isFalse);
    expect(
      File('${tmp.path}/gui.json').readAsStringSync(),
      contains('"start_fullscreen"'),
    );
  });
  test('auto_save_traffic: on when missing, saved when off', () {
    File('${tmp.path}/gui.json').writeAsStringSync('{"theme":"matrix","start_fullscreen":true}');
    expect(UiPrefs.load(tmp.path).autoSaveTraffic, isTrue);
    expect(UiPrefs().autoSaveTraffic, isTrue);
    UiPrefs(autoSaveTraffic: false).save(tmp.path);
    expect(File('${tmp.path}/gui.json').readAsStringSync(), contains('"auto_save_traffic":false'));
    expect(UiPrefs.load(tmp.path).autoSaveTraffic, isFalse);
  });
  test('corrupt json gives defaults', () {
    File('${tmp.path}/gui.json').writeAsStringSync('{nope');
    final p = UiPrefs.load(tmp.path);
    expect(p.theme, RappTheme.matrix);
    expect(p.startFullscreen, isTrue);
  });
  test('unknown theme name gives matrix', () {
    File(
      '${tmp.path}/gui.json',
    ).writeAsStringSync('{"theme":"graphite","start_fullscreen":false}');
    final p = UiPrefs.load(tmp.path);
    expect(p.theme, RappTheme.matrix);
    expect(p.startFullscreen, isFalse);
  });
  test('a saved IRON MAN (removed theme) gives matrix', () {
    File(
      '${tmp.path}/gui.json',
    ).writeAsStringSync('{"theme":"ironMan","start_fullscreen":false}');
    final p = UiPrefs.load(tmp.path);
    expect(p.theme, RappTheme.matrix);
    expect(p.startFullscreen, isFalse);
  });
  test('save into a missing dir creates it', () {
    final d = '${tmp.path}/a/b';
    UiPrefs(theme: RappTheme.avatar).save(d);
    expect(UiPrefs.load(d).theme, RappTheme.avatar);
  });
  test('save into a read-only dir throws FileSystemException', () {
    Process.runSync('chmod', ['500', tmp.path]);
    expect(() => UiPrefs().save(tmp.path), throwsA(isA<FileSystemException>()));
  });
}
