import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/local_ime.dart';

import 'fake_rime_link.dart';

/// A fake `run`: [answers] maps `exe args…` to (exit code, stdout); anything else exits 127.
class _Run {
  _Run(this.answers, {this.throws = false});
  final Map<String, (int, String)> answers;
  final bool throws;
  final calls = <String>[];

  Future<ProcessResult> call(String exe, List<String> args) async {
    final line = [exe, ...args].join(' ');
    calls.add(line);
    if (throws) throw ProcessException(exe, args, 'not found', 2);
    final a = answers[line] ?? (127, '');
    return ProcessResult(0, a.$1, a.$2, '');
  }
}

void main() {
  group('LinuxLocalIme with fcitx5', () {
    test('current reads 1 as ASCII and 2 as active', () async {
      expect(await LinuxLocalIme(_Run({'fcitx5-remote': (0, '1\n')}).call).current(), (id: 'fcitx5', ascii: true));
      expect(await LinuxLocalIme(_Run({'fcitx5-remote': (0, '2\n')}).call).current(), (id: 'fcitx5', ascii: false));
    });

    test('toChinese opens it and says fcitx5; toEnglish closes it', () async {
      final run = _Run({'fcitx5-remote': (0, '1\n')});
      final ime = LinuxLocalIme(run.call);
      expect(await ime.toChinese('ibus:pinyin'), 'fcitx5');
      await ime.toEnglish();
      expect(run.calls, contains('fcitx5-remote -o'));
      expect(run.calls, contains('fcitx5-remote -c'));
      expect(run.calls.where((c) => c.startsWith('ibus')), isEmpty);
    });

    test('an fcitx5-remote that answers 0 (not running) is not fcitx5', () async {
      final run = _Run({'fcitx5-remote': (0, '0\n')});
      expect(await LinuxLocalIme(run.call).current(), isNull);
      expect(run.calls, contains('ibus engine'));
    });
  });

  group('LinuxLocalIme with ibus', () {
    test('current names the engine; xkb: engines are ASCII', () async {
      expect(await LinuxLocalIme(_Run({'ibus engine': (0, 'libpinyin\n')}).call).current(),
          (id: 'ibus:libpinyin', ascii: false));
      expect(await LinuxLocalIme(_Run({'ibus engine': (0, 'xkb:us::eng\n')}).call).current(),
          (id: 'ibus:xkb:us::eng', ascii: true));
    });

    test('toChinese sets the saved ibus engine', () async {
      final run = _Run({'ibus engine': (0, 'xkb:us::eng\n'), 'ibus engine libpinyin': (0, '')});
      expect(await LinuxLocalIme(run.call).toChinese('ibus:libpinyin'), 'ibus:libpinyin');
      expect(run.calls.last, 'ibus engine libpinyin');
    });

    test('toChinese without a saved ibus engine runs nothing and says null', () async {
      for (final p in [null, 'fcitx5', 'com.apple.inputmethod.SCIM.ITABC']) {
        final run = _Run({'ibus engine': (0, 'xkb:us::eng\n')});
        expect(await LinuxLocalIme(run.call).toChinese(p), isNull, reason: '$p');
        expect(run.calls.where((c) => c.startsWith('ibus engine ')), isEmpty, reason: '$p');
      }
    });

    test('toEnglish picks the US keyboard engine', () async {
      final run = _Run({'ibus engine': (0, 'libpinyin\n')});
      await LinuxLocalIme(run.call).toEnglish();
      expect(run.calls.last, 'ibus engine xkb:us::eng');
    });
  });

  test('neither: null and nothing done', () async {
    final run = _Run({});
    final ime = LinuxLocalIme(run.call);
    expect(await ime.current(), isNull);
    expect(await ime.toChinese('ibus:libpinyin'), isNull);
    await ime.toEnglish();
    expect(run.calls.toSet(), {'fcitx5-remote', 'ibus engine'});
  });

  test('ProcessException: null and nothing thrown', () async {
    final ime = LinuxLocalIme(_Run({}, throws: true).call);
    expect(await ime.current(), isNull);
    expect(await ime.toChinese('ibus:libpinyin'), isNull);
    await ime.toEnglish();
  });

  test('RimeLocalIme: Chinese turns ascii off, English and current do nothing', () async {
    final link = FakeRimeLink();
    final ime = RimeLocalIme(link);
    expect(await ime.toChinese('x'), 'rime');
    await ime.toEnglish();
    expect(await ime.current(), isNull);
    expect(link.calls.where((c) => c.startsWith('ascii')), ['ascii:false']);
  });

  test('NoLocalIme does nothing', () async {
    const ime = NoLocalIme();
    expect(await ime.toChinese('x'), isNull);
    await ime.toEnglish();
    expect(await ime.current(), isNull);
  });
}
