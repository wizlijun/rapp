import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/paths.dart';

void main() {
  String? Function(String) fileAt(String path, String text) => (p) => p == path ? text : null;
  String? none(String _) => null;

  group('dataRoot', () {
    final ptr = '/Users/u/Library/Application Support/rapp/data-root';
    test('RAPP_HOME, then the pointer, then ~/rapp', () {
      final read = fileAt(ptr, '/Volumes/D/rapp\n');
      expect(dataRoot({'RAPP_HOME': '/h', 'HOME': '/Users/u'}, 'macos', read: read), '/h');
      expect(dataRoot({'HOME': '/Users/u'}, 'macos', read: read), '/Volumes/D/rapp');
      expect(dataRoot({'HOME': '/Users/u'}, 'macos', read: none), '/Users/u/rapp');
      expect(dataRoot({'RAPP_HOME': '', 'HOME': '/Users/u'}, 'macos', read: none), '/Users/u/rapp');
    });
    test('a bad pointer is ignored; only the first line counts', () {
      for (final text in ['', '  \n', 'rapp\n', '~/x']) {
        expect(dataRoot({'HOME': '/Users/u'}, 'macos', read: (_) => text), '/Users/u/rapp', reason: '"$text"');
      }
      expect(dataRoot({'HOME': '/Users/u'}, 'macos', read: (_) => '\n/a/b\n'), '/Users/u/rapp');
      expect(dataRoot({'HOME': '/Users/u'}, 'macos', read: (_) => '/a/b\nextra\n'), '/a/b');
      expect(dataRoot({'HOME': '/Users/u'}, 'macos', read: (_) => '  /a/b  \n'), '/a/b');
    });
    test('linux and windows', () {
      final lin = {'HOME': '/home/u', 'XDG_CONFIG_HOME': '/xdg'};
      expect(dataRoot(lin, 'linux', read: none), '/home/u/rapp');
      final win = {'USERPROFILE': r'C:\Users\u', 'APPDATA': r'C:\R'};
      expect(dataRoot(win, 'windows', read: none), r'C:\Users\u\rapp');
      expect(dataRoot(win, 'windows', read: fileAt(r'C:\R\rapp\data-root', r'D:\rapp')), r'D:\rapp');
      expect(dataRoot(win, 'windows', read: (_) => r'\\srv\share\rapp'), r'\\srv\share\rapp');
      expect(dataRoot(win, 'windows', read: (_) => 'D:/rapp'), 'D:/rapp');
    });
    test('defaultDataRoot', () {
      expect(defaultDataRoot({'HOME': '/Users/u'}, 'macos'), '/Users/u/rapp');
      expect(defaultDataRoot({'USERPROFILE': r'C:\Users\u'}, 'windows'), r'C:\Users\u\rapp');
    });
  });

  group('platformConfigDir', () {
    test('macOS ignores RAPP_HOME', () {
      expect(platformConfigDir({'RAPP_HOME': '/h', 'HOME': '/Users/u'}, 'macos'),
          '/Users/u/Library/Application Support/rapp');
    });
    test('linux XDG and fallback', () {
      expect(platformConfigDir({'HOME': '/home/u', 'XDG_CONFIG_HOME': '/xdg'}, 'linux'), '/xdg/rapp');
      expect(platformConfigDir({'HOME': '/home/u'}, 'linux'), '/home/u/.config/rapp');
    });
    test('windows APPDATA', () {
      expect(platformConfigDir({'APPDATA': r'C:\R'}, 'windows'), r'C:\R\rapp');
    });
  });

  group('legacyDir', () {
    test('RAPP_HOME or the old config dir', () {
      expect(legacyDir({'RAPP_HOME': '/h', 'HOME': '/Users/u'}, 'macos'), '/h');
      expect(legacyDir({'HOME': '/Users/u'}, 'macos'), '/Users/u/Library/Application Support/rapp');
    });
  });

  group('pointerFile', () {
    test('lives in the platform config dir', () {
      expect(pointerFile({'HOME': '/Users/u'}, 'macos'), '/Users/u/Library/Application Support/rapp/data-root');
      expect(pointerFile({'APPDATA': r'C:\R'}, 'windows'), r'C:\R\rapp\data-root');
    });
  });

  group('DataDir', () {
    test('sub paths', () {
      const d = DataDir('/r');
      expect([d.localDir, d.sharedDir, d.deviceDir('123456789'), d.filesDir, d.clipboardDir, d.filesClipboardDir],
          ['/r/local', '/r/shared', '/r/devices/123456789', '/r/files', '/r/clipboard', '/r/files/clipboard']);
    });
    test('deviceId and prefsDir', () {
      final t = Directory.systemTemp.createTempSync('rapp_dd');
      addTearDown(() => t.deleteSync(recursive: true));
      final d = DataDir(t.path);
      expect(d.deviceId(), isNull);
      expect(d.prefsDir(), isNull);
      Directory(d.localDir).createSync();
      void put(String s) => File('${d.localDir}/service.json').writeAsStringSync(s);
      put('{"id":"123456789"}');
      expect(d.deviceId(), '123456789');
      expect(d.prefsDir(), '${t.path}/devices/123456789');
      put('{"id":null}');
      expect(d.deviceId(), isNull);
      put('{"id":""}');
      expect(d.deviceId(), isNull);
      put('{"id":5}');
      expect(d.deviceId(), isNull);
      put('{');
      expect(d.deviceId(), isNull);
      expect(d.prefsDir(), isNull);
    });
  });

  group('logDir (same rules as rapp_net::log::log_dir)', () {
    test('RAPP_LOG_DIR, then RAPP_HOME/local/logs', () {
      expect(logDir({'RAPP_LOG_DIR': '/l', 'RAPP_HOME': '/h', 'HOME': '/Users/u'}, 'macos'), '/l');
      expect(logDir({'RAPP_HOME': '/h', 'HOME': '/Users/u'}, 'macos'), '/h/local/logs');
    });
    test('platform defaults', () {
      expect(logDir({'HOME': '/Users/u'}, 'macos'), '/Users/u/Library/Logs/rapp');
      expect(logDir({'HOME': '/home/u', 'XDG_STATE_HOME': '/st'}, 'linux'), '/st/rapp');
      expect(logDir({'HOME': '/home/u'}, 'linux'), '/home/u/.local/state/rapp');
      expect(logDir({'LOCALAPPDATA': r'C:\L'}, 'windows'), r'C:\L\rapp\logs');
    });
  });

  group('binDir / findBinary', () {
    test('RAPP_BIN_DIR wins over executable dir', () {
      expect(binDir({'RAPP_BIN_DIR': '/bins'}, '/A/rapp.app/Contents/MacOS/rapp'), '/bins');
      expect(binDir({}, '/A/rapp.app/Contents/MacOS/rapp'), '/A/rapp.app/Contents/MacOS');
    });

    test('finds an existing file and returns null otherwise', () {
      final d = Directory.systemTemp.createTempSync('rapp_bin');
      addTearDown(() => d.deleteSync(recursive: true));
      expect(findBinary('rapp-hub', d.path, 'macos'), isNull);
      File('${d.path}/rapp-hub').writeAsStringSync('');
      expect(findBinary('rapp-hub', d.path, 'macos'), '${d.path}/rapp-hub');
      File('${d.path}/rapp-hub.exe').writeAsStringSync('');
      // The .exe suffix follows the target OS; the separator follows the host.
      expect(findBinary('rapp-hub', d.path, 'windows'), '${d.path}${Platform.pathSeparator}rapp-hub.exe');
    });
  });
}
