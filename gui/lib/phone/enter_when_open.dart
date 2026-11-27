/// Goes into a session once it is really open, not before (V1b). Used by the devices page and the home page.
library;

import '../ui/main_state.dart';
import 'phone_nav.dart';

/// A not-open entry the user tapped: wait for it to be the current session with a sid, then `nav.enter` it once.
/// A stopped terminal starts a new one under another id, so it waits for the device's next current session
/// instead of its own key.
class EnterWhenOpen {
  EnterWhenOpen(this.state, this.nav) {
    state.addListener(_onState);
  }
  final MainState state;
  final PhoneNav nav;

  ({String device, String key, bool stopped, String? before})? _pending;

  bool get armed => _pending != null;

  /// Whether [key] is an open session (it has a sid), as opposed to a placeholder still opening.
  bool isOpen(String key) => state.entries.any((e) => e.key == key && e.sid != null);

  void arm({required String device, required String key, bool stopped = false}) {
    _pending = (device: device, key: key, stopped: stopped, before: state.currentKey);
  }

  void cancel() => _pending = null;

  void dispose() {
    state.removeListener(_onState);
    _pending = null;
  }

  void _onState() {
    final p = _pending;
    if (p == null) return;
    final cur = state.currentKey;
    if (cur == null || !isOpen(cur)) return;
    final landed = p.stopped ? cur != p.before && cur.startsWith('${p.device}/') : cur == p.key;
    if (!landed) return;
    _pending = null;
    nav.enter(cur);
  }
}
