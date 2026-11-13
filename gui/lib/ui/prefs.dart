import 'dart:convert';
import 'dart:io';

import 'tokens.dart';

/// GUI preferences, stored in `<dir>/gui.json` (`devices/<id>/` in the data root).
class UiPrefs {
  UiPrefs({this.theme = RappTheme.matrix, this.startFullscreen = true});

  RappTheme theme;
  bool startFullscreen;

  /// Never throws: a missing or corrupt file gives the defaults.
  static UiPrefs load(String dir) {
    try {
      final j = jsonDecode(File('$dir/gui.json').readAsStringSync());
      if (j is! Map) return UiPrefs();
      final name = j['theme'];
      final fs = j['start_fullscreen'];
      return UiPrefs(
        theme: RappTheme.values.firstWhere(
          (t) => t.name == name,
          orElse: () => RappTheme.matrix,
        ),
        startFullscreen: fs is bool ? fs : true,
      );
    } catch (_) {
      return UiPrefs();
    }
  }

  /// Synchronous; creates [dir] if needed. Throws [FileSystemException].
  void save(String dir) {
    Directory(dir).createSync(recursive: true);
    File('$dir/gui.json').writeAsStringSync(
      jsonEncode({'theme': theme.name, 'start_fullscreen': startFullscreen}),
    );
  }
}
