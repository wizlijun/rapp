import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/embed/strip_cmds.dart';
import 'package:rapp/ui/prefs.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rapp_phrases'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('missing file: the strip is on and the defaults are there', () {
    final p = UiPrefs.load(tmp.path);
    expect(p.phraseStrip, isTrue);
    expect(p.phrases, defaultStripItems);
    expect(p.phraseCmdsSeeded, isTrue);
  });

  test('an old file gets the seven commands in front, once', () {
    File('${tmp.path}/gui.json').writeAsStringSync('{"phrases":[{"text":"a"}]}');
    final p = UiPrefs.load(tmp.path);
    expect(p.phrases, [for (final id in builtinCmdOrder) StripCmd(id), const Phrase('a')]);
    expect(p.phraseCmdsSeeded, isTrue);
  });

  test('an old file without 切模式 gets it, right after 新对话', () {
    File('${tmp.path}/gui.json').writeAsStringSync('{"phrases":[{"text":"a"}]}');
    final p = UiPrefs.load(tmp.path);
    expect(p.phrases.whereType<StripCmd>().map((c) => c.id).take(2), ['new', 'mode']);
  });

  test('deleting every command sticks after save and load', () {
    File('${tmp.path}/gui.json').writeAsStringSync('{"phrases":[{"text":"a"}]}');
    final p = UiPrefs.load(tmp.path);
    p.phrases = p.phrases.whereType<Phrase>().toList();
    p.save(tmp.path);
    expect(UiPrefs.load(tmp.path).phrases, const [Phrase('a')]);
  });

  test('a seeded file is read back as it is', () {
    File('${tmp.path}/gui.json')
        .writeAsStringSync('{"phrases":[{"kind":"cmd","id":"new"},{"text":"a"}],"phrase_cmds_seeded":true}');
    expect(UiPrefs.load(tmp.path).phrases, const [StripCmd('new'), Phrase('a')]);
  });

  test('round-trips the switch, the order and 放进输入框', () {
    UiPrefs(phraseStrip: false, phrases: const [Phrase('b', put: true), Phrase('a')]).save(tmp.path);
    final p = UiPrefs.load(tmp.path);
    expect(p.phraseStrip, isFalse);
    expect(p.phrases, const [Phrase('b', put: true), Phrase('a')]);
  });

  test('an empty list stays empty; bad entries are dropped; a non-list means the defaults', () {
    UiPrefs(phrases: const []).save(tmp.path);
    expect(UiPrefs.load(tmp.path).phrases, isEmpty);
    File('${tmp.path}/gui.json')
        .writeAsStringSync('{"phrases":[{"text":"ok"},{"text":"  "},3,{"put":true}],"phrase_cmds_seeded":true}');
    expect(UiPrefs.load(tmp.path).phrases, const [Phrase('ok')]);
    File('${tmp.path}/gui.json').writeAsStringSync('{"phrases":"x","phrase_strip":"x"}');
    final p = UiPrefs.load(tmp.path);
    expect(p.phrases, defaultStripItems);
    expect(p.phraseStrip, isTrue);
  });

  test('the defaults list is not shared between prefs', () {
    final a = UiPrefs();
    a.phrases.add(const Phrase('x'));
    expect(UiPrefs().phrases, defaultStripItems);
  });
}
