import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/window_rules.dart';

RemoteWindow w(int id, {WindowKind kind = WindowKind.normal, int parent = 0, String? title}) =>
    RemoteWindow(
      id: id,
      parent: parent,
      kind: kind,
      title: title ?? 'w$id',
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      titleBar: 28,
      resizable: true,
      focused: false,
      texture: id,
      visible: const Rect.fromLTWH(0, 0, 1, 1),
    );

void main() {
  test('the main window is the earliest plain parentless one; it outlives a newer one', () {
    final t = MainWindowTracker();
    expect(t.update([w(9, kind: WindowKind.dialog), w(7), w(5)]), 5); // same table: by id
    expect(t.update([w(3), w(7), w(5)]), 5); // 3 is newer
    expect(t.update([w(3), w(7)]), 7);
    expect(t.update([w(4, kind: WindowKind.floating)]), isNull);
  });

  test('first matching rule wins; child defaults to sub-windows only', () {
    final rules = [const WindowRule(kind: WindowKind.dialog, action: RuleAction.noComposer),
                   const WindowRule(action: RuleAction.hide)];
    expect(actionFor(rules, w(2, kind: WindowKind.dialog), isMain: false), RuleAction.noComposer);
    expect(actionFor(rules, w(3), isMain: false), RuleAction.hide);
    expect(actionFor(rules, w(1), isMain: true), isNull);
    expect(actionFor([const WindowRule(child: false, action: RuleAction.noComposer)], w(1), isMain: true),
        RuleAction.noComposer);
  });

  test('title glob matches case-insensitively; no title means any title', () {
    const r = WindowRule(kind: WindowKind.floating, title: '*下载*', action: RuleAction.hide);
    expect(ruleMatches(r, w(2, kind: WindowKind.floating, title: 'Chrome 下载'), isMain: false), isTrue);
    expect(ruleMatches(r, w(2, kind: WindowKind.dialog, title: 'Chrome 下载'), isMain: false), isFalse);
    expect(ruleMatches(r, w(2, kind: WindowKind.floating, title: '设置'), isMain: false), isFalse);
  });

  test('hide drops the window; the main window is never hidden by a default rule', () {
    final r = applyHide([w(1), w(2), w(3)], [const WindowRule(action: RuleAction.hide)], main: 1);
    expect(r.shown.map((e) => e.id), [1]);
    expect(r.hidden.map((e) => e.id), [2, 3]);
  });

  test('popups of a hidden window go with it, an orphan popup stays', () {
    final all = [w(1), w(2, kind: WindowKind.floating), w(5, kind: WindowKind.menu, parent: 2),
                 w(6, kind: WindowKind.sheet, parent: 1), w(7, kind: WindowKind.popover, parent: 99)];
    final r = applyHide(all, [const WindowRule(kind: WindowKind.floating, action: RuleAction.hide)], main: 1);
    expect(r.shown.map((e) => e.id), [1, 6, 7]);
    expect(r.hidden.map((e) => e.id), [2]); // the count is of windows a rule hid (R4)
  });

  test('only hidden windows left: everything shows (D7)', () {
    final rules = [const WindowRule(child: false, action: RuleAction.hide)];
    final r = applyHide([w(1), w(2), w(5, kind: WindowKind.menu, parent: 1)], rules, main: 1);
    expect(r.shown.map((e) => e.id), [1, 2, 5]);
    expect(r.hidden, isEmpty);
  });

  test('showOnce brings one hidden window and its popups back', () {
    final all = [w(1), w(2), w(5, kind: WindowKind.menu, parent: 2), w(3)];
    final r = applyHide(all, [const WindowRule(action: RuleAction.hide)], main: 1, showOnce: {2});
    expect(r.shown.map((e) => e.id), [1, 2, 5]);
    expect(r.hidden.map((e) => e.id), [3]);
  });
}
