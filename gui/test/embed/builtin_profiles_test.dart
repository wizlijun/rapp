import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';

void main() {
  final raw = jsonDecode(File('assets/app_profiles.json').readAsStringSync()) as Map<String, Object?>;
  final apps = parseProfiles(raw);

  test('18 built-in profiles, the §9 names in order', () {
    expect(apps.map((p) => p.name), [
      '终端', 'iTerm2', 'Ghostty', 'Warp', 'ChatGPT', 'Claude', 'Cursor', 'VS Code',
      'Xcode', 'Chrome', 'Safari', 'Edge', 'WPS Office', 'Word、Excel、PowerPoint', '微信', '企业微信', 'Paseo', 'note.md',
    ]);
  });

  test('every row: authoring field order, none / true / [] / tested false', () {
    for (final e in (raw['apps'] as List).cast<Map>()) {
      expect(e.keys.toList(), ['name', 'ids', 'stream', 'afterSend', 'composer', 'windows', 'tested']);
      expect(e['afterSend'], 'none');
      expect(e['composer'], true);
      expect(e['windows'], isEmpty);
      expect(e['tested'], false);
    }
  });

  test('the §9 ids and pictures', () {
    String key(AppProfile p) => '${p.ids.join(',')} ${p.mode}/${p.density}/${p.fps}';
    expect(apps.map(key), [
      'com.apple.Terminal duogray/adaptive/15',
      'com.googlecode.iterm2 duogray/adaptive/15',
      'com.mitchellh.ghostty duogray/adaptive/15',
      'dev.warp.Warp-Stable duocolor/adaptive/15',
      'com.openai.codex,com.openai.chat duocolor/adaptive/15',
      'com.anthropic.claudefordesktop duocolor/adaptive/15',
      'com.todesktop.230313mzl4w4u92 duocolor/adaptive/15',
      'com.microsoft.VSCode duocolor/adaptive/15',
      'com.apple.dt.Xcode duocolor/adaptive/15',
      'com.google.Chrome color16/adaptive/15',
      'com.apple.Safari color16/adaptive/15',
      'com.microsoft.edgemac color16/adaptive/15',
      'com.kingsoft.wpsoffice.mac.global,com.kingsoft.wpsoffice.mac duocolor/adaptive/5',
      'com.microsoft.Word,com.microsoft.Excel,com.microsoft.Powerpoint duocolor/adaptive/5',
      'com.tencent.xinWeChat duocolor/adaptive/5',
      'com.tencent.WeWorkMac duocolor/adaptive/5',
      'sh.paseo.desktop duocolor/adaptive/15',
      'net.notemd.app duocolor/adaptive/5',
    ]);
  });

  test('no id appears in two built-in profiles', () {
    final all = [for (final p in apps) ...p.ids.map((i) => i.toLowerCase())];
    expect(all.toSet().length, all.length);
  });

  test('pubspec lists the asset', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('- assets/app_profiles.json'));
  });
}
