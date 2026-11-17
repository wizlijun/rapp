import 'dart:convert';
import 'dart:io';

import 'tokens.dart';

/// Which layer the window opens on (`first` in gui.json): the devices or the projects.
enum FirstLayer { device, project }

/// Size factor of each writing-panel zoom step (⌘= / ⌘- / ⌘0): the default, then four larger.
const composerZoomScales = [1.0, 1.15, 1.3, 1.5, 1.75];

/// The top zoom step; 0 is the default and the smallest.
final composerZoomMax = composerZoomScales.length - 1;

/// GUI preferences, stored in `<dir>/gui.json` (`devices/<id>/` in the data root).
class UiPrefs {
  UiPrefs({
    this.theme = RappTheme.matrix,
    this.startFullscreen = true,
    this.autoSaveTraffic = true,
    this.inputHistory = true,
    this.termKeyRow = false,
    this.termFit = true,
    this.keepAwake = true,
    this.first = FirstLayer.device,
    this.composerZoom = 0,
    Map<String, String>? termOpen,
    Map<String, String>? termApp,
  })  : termOpen = termOpen ?? {},
        termApp = termApp ?? {};

  RappTheme theme;
  bool startFullscreen;

  /// 网络差时自动省流量 (`auto_save_traffic`): A may lower the stream below the choice while the
  /// network is poor. Missing means on.
  bool autoSaveTraffic;

  /// 记下写作面板发出去的话 (`input_history`): the input record is kept. Missing or bad means on.
  bool inputHistory;

  /// 按键排 (`term_key_row`): the six big keys on a terminal's stage, on this console. Missing or bad means off.
  bool termKeyRow;

  /// 跟着我的窗口 (`term_fit`): the host's terminal window follows this console's size. Missing or bad means on.
  bool termFit;

  /// 屏幕常亮 (`keep_awake`, iOS): no auto-lock while a live session is on the stage. Missing or bad means on.
  bool keepAwake;

  /// 输入板缩放档 (`composer_zoom`): 0 is the default size, up to [composerZoomMax]. Missing or bad means 0.
  int composerZoom;

  /// 排列 (`first`): the layer shown first. Missing or unknown means devices.
  FirstLayer first;

  /// 终端打开方式 (`term_open`): device id to `text` or `pixels`. Unknown values are dropped on load.
  final Map<String, String> termOpen;

  String termOpenFor(String device) => termOpen[device] ?? 'text';

  /// 终端 app (`term_app`): device id to the terminal app a new text terminal opens in. Non-string values are
  /// dropped on load.
  final Map<String, String> termApp;

  /// The stored app when [launchers] still has it, else the first launcher.
  String termAppFor(String device, List<String> launchers) {
    final a = termApp[device];
    return a != null && launchers.contains(a) ? a : launchers.first;
  }

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
      final tf = j['term_fit'];
      final ka = j['keep_awake'];
      final fl = j['first'];
      final cz = j['composer_zoom'];
      final to = j['term_open'];
      final ta = j['term_app'];
      return UiPrefs(
        theme: RappTheme.values.firstWhere(
          (t) => t.name == name,
          orElse: () => RappTheme.matrix,
        ),
        startFullscreen: fs is bool ? fs : true,
        autoSaveTraffic: save is bool ? save : true,
        inputHistory: ih is bool ? ih : true,
        termKeyRow: kr is bool ? kr : false,
        termFit: tf is bool ? tf : true,
        keepAwake: ka is bool ? ka : true,
        composerZoom: cz is int ? cz.clamp(0, composerZoomMax) : 0,
        first: FirstLayer.values.firstWhere(
          (v) => v.name == fl,
          orElse: () => FirstLayer.device,
        ),
        termOpen: {
          if (to is Map)
            for (final e in to.entries)
              if (e.key is String && (e.value == 'text' || e.value == 'pixels')) e.key as String: e.value as String,
        },
        termApp: {
          if (ta is Map)
            for (final e in ta.entries)
              if (e.key is String && e.value is String) e.key as String: e.value as String,
        },
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
        'term_fit': termFit,
        'keep_awake': keepAwake,
        'first': first.name,
        'composer_zoom': composerZoom,
        'term_open': termOpen,
        'term_app': termApp,
      }),
    );
  }
}
