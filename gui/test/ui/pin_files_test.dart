import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/pin_files.dart';

void main() {
  test('pinStem: time, cleaned 20-char title, kind word when empty', () {
    final at = DateTime(2026, 11, 13, 9, 5, 7);
    expect(pinStem(at, '你好 世界', ClipKind.text), '20261113-090507-你好 世界');
    expect(pinStem(at, 'a/b\\c:d*e?f"g<h>i|j\nk', ClipKind.text), '20261113-090507-abcdefghijk');
    expect(pinStem(at, '..hidden', ClipKind.text), '20261113-090507-hidden');
    expect(pinStem(at, '一二三四五六七八九十一二三四五六七八九十多', ClipKind.text).length, 16 + 20);
    expect(pinStem(at, '  \n ', ClipKind.text), '20261113-090507-文字');
    expect(pinStem(at, '', ClipKind.image), '20261113-090507-图片');
  });

  test('pinnedPaths lists both places, skips temp and hidden files; title and time come back', () {
    final root = Directory.systemTemp.createTempSync('pin_files_test');
    addTearDown(() => root.deleteSync(recursive: true));
    final d = DataDir(root.path);
    Directory(d.clipboardDir).createSync(recursive: true);
    Directory(d.filesClipboardDir).createSync(recursive: true);
    final a = '${d.clipboardDir}/20261113-090507-a.md';
    File(a).writeAsStringSync('x');
    File('${d.clipboardDir}/.x').writeAsStringSync('x');
    File('${d.clipboardDir}/b.md.tmp').writeAsStringSync('x');
    File('${d.filesClipboardDir}/20261113-090508-图片.png').writeAsStringSync('x');
    Directory('${d.filesClipboardDir}/20261113-090509-文件').createSync();
    final p = pinnedPaths(d);
    expect(p.length, 3);
    expect(p.first, a);
    expect(pinTitle(a), 'a');
    expect(pinTitle(p[1]), '图片');
    expect(pinTitle(p[2]), '文件');
    expect(pinTime(a), DateTime(2026, 11, 13, 9, 5, 7));
    expect(pinTime('${d.clipboardDir}/zzz.md'), isNull);
    deletePin(a);
    deletePin(p[2]);
    deletePin('${d.clipboardDir}/nope');
    expect(pinnedPaths(d).length, 1);
  });
}
