// `local/state.json`: how this app finds the center service (rapp-center). See the config reference, section on state.json.
import 'dart:convert';
import 'dart:io';

import '../data_dir.dart' show writePrivate;

enum StateMode { auto, off, manual }

class StateConfig {
  const StateConfig(this.mode, {this.url = ''});

  final StateMode mode;
  final String url;

  static const _file = 'state.json';

  /// A missing, unreadable or unknown file means [StateMode.auto].
  static StateConfig load(String localDir) {
    try {
      final j = jsonDecode(File('$localDir/$_file').readAsStringSync());
      if (j is! Map) return const StateConfig(StateMode.auto);
      switch (j['mode']) {
        case 'off':
          return const StateConfig(StateMode.off);
        case 'manual':
          final u = j['url'];
          return StateConfig(StateMode.manual, url: u is String ? u : '');
        default:
          return const StateConfig(StateMode.auto);
      }
    } catch (_) {
      return const StateConfig(StateMode.auto);
    }
  }

  void save(String localDir) {
    final body = {'mode': mode.name, if (mode == StateMode.manual) 'url': url};
    writePrivate('$localDir/$_file', utf8.encode(jsonEncode(body)));
  }

  /// null when [s] is a usable address, otherwise the hint to show the user.
  static String? checkUrl(String s) {
    final u = Uri.tryParse(s.trim());
    final ok = u != null && (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty;
    return ok ? null : '地址要以 http:// 或 https:// 开头';
  }
}
