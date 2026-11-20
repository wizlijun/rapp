// The app's side of the built-in input method (iOS, hardware keyboard). rapp_rime knows nothing of prefs,
// profiles or sessions; this file is the one place that tells it what they say:
// - 全局设置's 实体键盘用内置输入法 and 词库 (UiPrefs) → enabled, dictionary;
// - the session on the stage → 「内」/「系」, from its app profile's `rime`;
// - a tap on 「内」/「系」 → that session's app profile, and only that one.
import 'package:rapp_rime/rapp_rime.dart';

import '../ui/main_state.dart';
import 'remote_session.dart';

class RimeGlue {
  /// Follows [state] until [dispose]. [rime] is the engine's Dart side (tests pass their own).
  RimeGlue(this.state, {RappRime? rime}) : rime = rime ?? RappRime.instance {
    state.addListener(_apply);
    _apply();
  }

  final MainState state;
  final RappRime rime;

  /// 「内」/「系」 of a session whose app has no id: no profile to keep it in, so it lasts as long as the session.
  final _unkept = Expando<bool>('rime');

  bool get enabled => state.prefs.rimeEnabled;

  RimeDictionary get dictionary =>
      state.prefs.rimeDictionary == 'user' ? RimeDictionary.user : RimeDictionary.bundled;

  /// 「内」 unless the session's app profile says 「系」; with no session on the stage, 「内」.
  bool _builtinFor(RemoteSession? rs) => rs == null ? true : (_unkept[rs] ?? rs.profile.rime);

  void _apply() => rime.configure(
        enabled: enabled,
        builtin: _builtinFor(state.currentRemote),
        dictionary: dictionary,
        onBuiltin: _remember,
      );

  void _remember(bool builtin) {
    final rs = state.currentRemote;
    if (rs == null) return;
    if (rs.appId.isEmpty) {
      _unkept[rs] = builtin;
      _apply();
    } else {
      state.profiles.setRime(rs.appId, rs.appName, builtin); // the store notifies; the state follows; so do we
    }
  }

  void setDictionary(RimeDictionary d) => state.setRimeDictionary(d == RimeDictionary.user ? 'user' : 'bundled');

  Future<void> redeploy() => rime.redeploy();

  Future<({String path, bool ready})> userFolder() => rime.userFolder();

  void dispose() => state.removeListener(_apply);
}
