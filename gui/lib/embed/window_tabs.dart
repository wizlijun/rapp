// Which of A's windows is the current tab, and which popups belong over it (R8, R9).
import 'session_port.dart';

class WindowTabs {
  List<RemoteWindow> _tabs = const [];
  int? _current;

  /// Most recently used last; ids may be gone.
  final List<int> _mru = [];

  int? get current => _current;

  /// The decorated windows, in A's order.
  List<RemoteWindow> get tabs => _tabs;

  void _touch(int id) {
    _mru.remove(id);
    _mru.add(id);
  }

  /// A new window table: a new decorated window becomes current (the first of several); when the
  /// current one is gone the most recently used one still there takes over.
  void update(List<RemoteWindow> all) {
    final before = {for (final w in _tabs) w.id};
    _tabs = [for (final w in all) if (w.decorated) w];
    final ids = {for (final w in _tabs) w.id};
    _mru.removeWhere((id) => !ids.contains(id));
    final fresh = _tabs.where((w) => !before.contains(w.id));
    if (fresh.isNotEmpty) {
      _current = fresh.first.id;
      _touch(_current!);
    } else if (_current == null || !ids.contains(_current)) {
      _current = _mru.isNotEmpty ? _mru.last : (_tabs.isEmpty ? null : _tabs.first.id);
    }
  }

  /// The user picked [id]; an id that is not a tab is ignored.
  void select(int id) {
    if (!_tabs.any((w) => w.id == id)) return;
    _current = id;
    _touch(id);
  }
}

/// The popups and sheets in [all] that go over the window [current], front to back as in [all].
/// A popup belongs to its parent's window; one whose parent is missing goes over [current] (R8).
List<RemoteWindow> popupsFor(List<RemoteWindow> all, int current) {
  RemoteWindow? byId(int id) {
    for (final w in all) {
      if (w.id == id) return w;
    }
    return null;
  }

  int rootOf(RemoteWindow w) {
    var p = byId(w.parent);
    for (var i = 0; i < all.length && p != null; i++) {
      if (p.decorated) return p.id;
      p = byId(p.parent);
    }
    return current;
  }

  return [
    for (final w in all)
      if (!w.decorated && w.texture != null && rootOf(w) == current) w,
  ];
}
