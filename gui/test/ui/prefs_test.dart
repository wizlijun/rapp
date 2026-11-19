import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/voice_key_gate.dart';
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
  test('rime fields: defaults, round trip, bad dictionary', () {
    final d = UiPrefs();
    expect([d.rimeEnabled, d.rimeBuiltin, d.rimeDictionary], [false, true, 'bundled']);
    File('${tmp.path}/gui.json').writeAsStringSync('{"rime_enabled":"x","rime_builtin":1,"rime_dictionary":"x"}');
    final bad = UiPrefs.load(tmp.path);
    expect([bad.rimeEnabled, bad.rimeBuiltin, bad.rimeDictionary], [false, true, 'bundled']);
    UiPrefs(rimeEnabled: true, rimeBuiltin: false, rimeDictionary: 'user').save(tmp.path);
    final back = UiPrefs.load(tmp.path);
    expect([back.rimeEnabled, back.rimeBuiltin, back.rimeDictionary], [true, false, 'user']);
  });

  test('keep_awake: on when missing or bad, saved when off', () {
    File('${tmp.path}/gui.json').writeAsStringSync('{"keep_awake":"x"}');
    expect(UiPrefs.load(tmp.path).keepAwake, isTrue);
    expect(UiPrefs().keepAwake, isTrue);
    UiPrefs(keepAwake: false).save(tmp.path);
    expect(File('${tmp.path}/gui.json').readAsStringSync(), contains('"keep_awake":false'));
    expect(UiPrefs.load(tmp.path).keepAwake, isFalse);
  });
  test('auto_save_traffic: on when missing, saved when off', () {
    File('${tmp.path}/gui.json').writeAsStringSync('{"theme":"matrix","start_fullscreen":true}');
    expect(UiPrefs.load(tmp.path).autoSaveTraffic, isTrue);
    expect(UiPrefs().autoSaveTraffic, isTrue);
    UiPrefs(autoSaveTraffic: false).save(tmp.path);
    expect(File('${tmp.path}/gui.json').readAsStringSync(), contains('"auto_save_traffic":false'));
    expect(UiPrefs.load(tmp.path).autoSaveTraffic, isFalse);
  });
  test('settings_folded: open by default and when bad, saved when folded', () {
    expect(UiPrefs().settingsFolded, isFalse);
    File('${tmp.path}/gui.json').writeAsStringSync('{"settings_folded":"x"}');
    expect(UiPrefs.load(tmp.path).settingsFolded, isFalse);
    UiPrefs(settingsFolded: true).save(tmp.path);
    expect(File('${tmp.path}/gui.json').readAsStringSync(), contains('"settings_folded":true'));
    expect(UiPrefs.load(tmp.path).settingsFolded, isTrue);
  });

  test('input_history: on by default and when bad, saved when off', () {
    expect(UiPrefs().inputHistory, isTrue);
    File('${tmp.path}/gui.json').writeAsStringSync('{"input_history":"x"}');
    expect(UiPrefs.load(tmp.path).inputHistory, isTrue);
    UiPrefs(inputHistory: false).save(tmp.path);
    expect(File('${tmp.path}/gui.json').readAsStringSync(), contains('"input_history":false'));
    expect(UiPrefs.load(tmp.path).inputHistory, isFalse);
  });
  test('term_fit: on by default and when missing or bad, saved when off', () {
    expect(UiPrefs().termFit, isTrue);
    expect(UiPrefs.load(tmp.path).termFit, isTrue);
    File('${tmp.path}/gui.json').writeAsStringSync('{"term_fit":"x"}');
    expect(UiPrefs.load(tmp.path).termFit, isTrue);
    UiPrefs(termFit: false).save(tmp.path);
    expect(File('${tmp.path}/gui.json').readAsStringSync(), contains('"term_fit":false'));
    expect(UiPrefs.load(tmp.path).termFit, isFalse);
  });

  test('term_key_row: off by default and when bad, saved when on', () {
    expect(UiPrefs().termKeyRow, isFalse);
    expect(UiPrefs.load(tmp.path).termKeyRow, isFalse);
    File('${tmp.path}/gui.json').writeAsStringSync('{"term_key_row":"x"}');
    expect(UiPrefs.load(tmp.path).termKeyRow, isFalse);
    UiPrefs(termKeyRow: true).save(tmp.path);
    expect(File('${tmp.path}/gui.json').readAsStringSync(), contains('"term_key_row":true'));
    expect(UiPrefs.load(tmp.path).termKeyRow, isTrue);
  });
  test('term_open round-trips and defaults to text', () {
    final p = UiPrefs()..termOpen['d1'] = 'pixels';
    p.save(tmp.path);
    final q = UiPrefs.load(tmp.path);
    expect((q.termOpenFor('d1'), q.termOpenFor('d2')), ('pixels', 'text'));
  });
  test('a bad term_open value is dropped', () {
    File('${tmp.path}/gui.json').writeAsStringSync('{"term_open":{"d1":"x","d2":"pixels","d3":4}}');
    expect(UiPrefs.load(tmp.path).termOpen, {'d2': 'pixels'});
    File('${tmp.path}/gui.json').writeAsStringSync('{"term_open":"nope"}');
    expect(UiPrefs.load(tmp.path).termOpen, isEmpty);
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
  test('first round-trips, defaults to device, and keeps the old fields', () {
    final p = UiPrefs(first: FirstLayer.project)..save(tmp.path);
    final back = UiPrefs.load(tmp.path);
    expect(back.first, FirstLayer.project);
    expect(back.theme, p.theme);
    expect(UiPrefs().first, FirstLayer.device);
    expect(UiPrefs.load('${tmp.path}/none').first, FirstLayer.device);
    expect(File('${tmp.path}/gui.json').readAsStringSync(), contains('"first":"project"'));
  });
  test('an unknown first is device', () {
    File('${tmp.path}/gui.json').writeAsStringSync('{"first":"sideways"}');
    expect(UiPrefs.load(tmp.path).first, FirstLayer.device);
  });
  test('term_app round-trips and a missing launcher falls back to the first', () {
    UiPrefs(termApp: {'d': 'iTerm', 'e': 'Terminal'}).save(tmp.path);
    final p = UiPrefs.load(tmp.path);
    expect(p.termApp, {'d': 'iTerm', 'e': 'Terminal'});
    expect(p.termAppFor('d', ['Terminal', 'iTerm']), 'iTerm');
    expect(p.termAppFor('d', ['Terminal']), 'Terminal');
    expect(p.termAppFor('zzz', ['iTerm', 'Terminal']), 'iTerm');
    File('${tmp.path}/gui.json').writeAsStringSync('{"term_app":{"a":"iTerm","b":3}}');
    expect(UiPrefs.load(tmp.path).termApp, {'a': 'iTerm'});
  });
  test('stage_buttons_side round-trips; missing or bad is right', () {
    UiPrefs(stageButtonsSide: StageSide.left).save(tmp.path);
    expect(UiPrefs.load(tmp.path).stageButtonsSide, StageSide.left);
    File('${tmp.path}/gui.json').writeAsStringSync('{}');
    expect(UiPrefs.load(tmp.path).stageButtonsSide, StageSide.right);
    File('${tmp.path}/gui.json').writeAsStringSync('{"stage_buttons_side":"up"}');
    expect(UiPrefs.load(tmp.path).stageButtonsSide, StageSide.right);
  });

  test('voice_hotkey and voice_language_hint_shown round-trip, with fallbacks', () {
    UiPrefs(voiceHotkey: const VoiceHotkey.holdCombo(49, 786432), voiceLanguageHintShown: true).save(tmp.path);
    final p = UiPrefs.load(tmp.path);
    expect(p.voiceHotkey, const VoiceHotkey.holdCombo(49, 786432));
    expect(p.voiceLanguageHintShown, isTrue);
    File('${tmp.path}/gui.json').writeAsStringSync('{"voice_hotkey":7}');
    expect(UiPrefs.load(tmp.path).voiceHotkey, VoiceHotkey.standard);
    File('${tmp.path}/gui.json').writeAsStringSync('{}');
    final d = UiPrefs.load(tmp.path);
    expect(d.voiceHotkey, VoiceHotkey.standard);
    expect(d.voiceLanguageHintShown, isFalse);
  });
}
