import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/paths.dart';

void main() {
  group('configDir', () {
    test('RAPP_HOME wins', () {
      expect(configDir({'RAPP_HOME': '/tmp/x', 'HOME': '/Users/u'}, 'macos'), '/tmp/x');
    });
    test('macOS default', () {
      expect(configDir({'HOME': '/Users/u'}, 'macos'), '/Users/u/Library/Application Support/rapp');
    });
    test('linux XDG and fallback', () {
      expect(configDir({'HOME': '/home/u', 'XDG_CONFIG_HOME': '/xdg'}, 'linux'), '/xdg/rapp');
      expect(configDir({'HOME': '/home/u'}, 'linux'), '/home/u/.config/rapp');
    });
    test('windows APPDATA', () {
      expect(configDir({'APPDATA': r'C:\Users\u\AppData\Roaming'}, 'windows'), r'C:\Users\u\AppData\Roaming\rapp');
    });
  });

  group('logDir (same rules as rapp_net::log::log_dir)', () {
    test('RAPP_LOG_DIR, then RAPP_HOME/logs', () {
      expect(logDir({'RAPP_LOG_DIR': '/l', 'RAPP_HOME': '/h', 'HOME': '/Users/u'}, 'macos'), '/l');
      expect(logDir({'RAPP_HOME': '/h', 'HOME': '/Users/u'}, 'macos'), '/h/logs');
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
