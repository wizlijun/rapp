// Window rules: which window is the main one, which rule matches, which windows to hide.
import 'app_profile.dart';
import 'session_port.dart';

/// Remembers the order in which window ids first appeared (R2) and names the main window.
class MainWindowTracker {
  final List<int> _order = [];

  /// The first plain parentless window by first appearance, or null.
  int? update(List<RemoteWindow> all) {
    final ids = {for (final w in all) w.id};
    _order.removeWhere((id) => !ids.contains(id));
    final seen = _order.toSet();
    _order.addAll([for (final id in ids) if (!seen.contains(id)) id]..sort());
    final candidates = {
      for (final w in all)
        if (w.kind == WindowKind.normal && w.parent == 0) w.id
    };
    for (final id in _order) {
      if (candidates.contains(id)) return id;
    }
    return null;
  }
}

bool ruleMatches(WindowRule r, RemoteWindow w, {required bool isMain}) =>
    (!r.child || !isMain) &&
    (r.kind == null || r.kind == w.kind) &&
    (r.title == null || globMatch(r.title!, w.title));

/// The action of the first rule that matches, or null.
RuleAction? actionFor(List<WindowRule> rules, RemoteWindow w, {required bool isMain}) {
  for (final r in rules) {
    if (ruleMatches(r, w, isMain: isMain)) return r.action;
  }
  return null;
}

/// Splits [all] into what to show and what a `hide` rule hid (R4, R5). [hidden] counts only the
/// windows a rule matched directly; their popups go with them but are not counted.
({List<RemoteWindow> shown, List<RemoteWindow> hidden}) applyHide(
  List<RemoteWindow> all,
  List<WindowRule> rules, {
  int? main,
  Set<int> showOnce = const {},
}) {
  RemoteWindow? byId(int id) {
    for (final w in all) {
      if (w.id == id) return w;
    }
    return null;
  }

  int? rootOf(RemoteWindow w) {
    var p = byId(w.parent);
    for (var i = 0; i < all.length && p != null; i++) {
      if (p.decorated) return p.id;
      p = byId(p.parent);
    }
    return null;
  }

  bool kept(RemoteWindow w) =>
      showOnce.contains(w.id) || (!w.decorated && showOnce.contains(rootOf(w)));

  final hidden = [
    for (final w in all)
      if (!kept(w) && actionFor(rules, w, isMain: w.id == main) == RuleAction.hide) w
  ];
  final hiddenIds = {for (final w in hidden) w.id};

  final shown = [
    for (final w in all)
      if (!hiddenIds.contains(w.id) && !(!w.decorated && hiddenIds.contains(rootOf(w)))) w
  ];
  final lostAllTitled = all.any((w) => w.decorated) && !shown.any((w) => w.decorated);
  if (lostAllTitled || (all.isNotEmpty && shown.isEmpty)) {
    return (shown: List.of(all), hidden: const <RemoteWindow>[]);
  }
  return (shown: shown, hidden: hidden);
}
