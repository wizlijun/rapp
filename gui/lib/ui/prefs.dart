import 'dart:convert';
import 'dart:io';

import 'tokens.dart';

/// Which layer the window opens on (`first` in gui.json): the devices or the projects.
enum FirstLayer { device, project }

/// GUI preferences, stored in `<dir>/gui.json` (`devices/<id>/` in the data root).
class UiPrefs {
  UiPrefs({
    this.theme = RappTheme.matrix,
    this.startFullscreen = true,
    this.autoSaveTraffic = true,
    this.inputHistory = true,
    this.termKeyRow = false,
    this.first = FirstLayer.device,
  });

  RappTheme theme;
  bool startFullscreen;

  /// 网络差时自动省流量 (`auto_save_traffic`): A may lower the stream below the choice while the
  /// network is poor. Missing means on.
  bool autoSaveTraffic;

  /// 记下写作面板发出去的话 (`input_history`): the input record is kept. Missing or bad means on.
  bool inputHistory;

  /// 按键排 (`term_key_row`): the six big keys on a terminal's stage, on this console. Missing or bad means off.
  bool termKeyRow;

  /// 排列 (`first`): the layer shown first. Missing or unknown means devices.
  FirstLayer first;

  /// Never throws: a missing or corrupt file gives the defaults.
  static UiPrefs load(String dir) {
    try {
      final j = jsonDecode(File('$dir/gui.json').readAsStringSync());
      if (j is! Map) return UiPrefs();
      final name = j['theme'];
      final fs = j['start_fullscreen'];
      final save = j['auto_save_traffic'];
      final ih = j['input_history'];
      final kr = j['term_key_row'];
      final fl = j['first'];
      return UiPrefs(
        theme: RappTheme.values.firstWhere(
          (t) => t.name == name,
          orElse: () => RappTheme.matrix,
        ),
        startFullscreen: fs is bool ? fs : true,
        autoSaveTraffic: save is bool ? save : true,
        inputHistory: ih is bool ? ih : true,
        termKeyRow: kr is bool ? kr : false,
        first: FirstLayer.values.firstWhere(
          (v) => v.name == fl,
          orElse: () => FirstLayer.device,
        ),
      );
    } catch (_) {
      return UiPrefs();
    }
  }

  /// Synchronous; creates [dir] if needed. Throws [FileSystemException].
  void save(String dir) {
    Directory(dir).createSync(recursive: true);
    File('$dir/gui.json').writeAsStringSync(
      jsonEncode({
        'theme': theme.name,
        'start_fullscreen': startFullscreen,
        'auto_save_traffic': autoSaveTraffic,
        'input_history': inputHistory,
        'term_key_row': termKeyRow,
        'first': first.name,
      }),
    );
  }
}
