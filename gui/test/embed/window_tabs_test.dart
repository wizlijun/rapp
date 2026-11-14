import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/window_tabs.dart';

RemoteWindow w(int id, {WindowKind kind = WindowKind.normal, int parent = 0, bool focused = false}) => RemoteWindow(
      id: id,
      parent: parent,
      kind: kind,
      title: 'w$id',
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      titleBar: 28,
      resizable: true,
      focused: focused,
      texture: id,
      visible: const Rect.fromLTWH(0, 0, 1, 1),
    );

void main() {
  late WindowTabs tabs;
  setUp(() => tabs = WindowTabs());

  test('new window becomes current; closing current falls back to MRU', () {
    tabs.update([w(1), w(2)]);
    expect(tabs.current, 1);
    tabs.select(2);
    tabs.update([w(1), w(2), w(3)]);
    expect(tabs.current, 3);
    tabs.update([w(1), w(2)]);
    expect(tabs.current, 2);
    tabs.update([w(1)]);
    expect(tabs.current, 1);
    tabs.update([]);
    expect(tabs.current, isNull);
  });

  test('popups and sheets are not tabs', () {
    tabs.update([w(1), w(5, kind: WindowKind.menu), w(6, kind: WindowKind.sheet, parent: 1)]);
    expect(tabs.tabs.map((e) => e.id), [1]);
    expect(tabs.current, 1);
  });

  test('a window that comes back counts as new; selecting an unknown id does nothing', () {
    tabs.update([w(1), w(2)]);
    tabs.select(9);
    expect(tabs.current, 1);
    tabs.update([w(2)]);
    expect(tabs.current, 2);
    tabs.update([w(1), w(2)]);
    expect(tabs.current, 1);
  });

  test('without followNew a new window does not take over, the focused one starts', () {
    tabs = WindowTabs(followNew: false);
    tabs.update([w(1), w(2, focused: true), w(3)]);
    expect(tabs.current, 2);
    tabs.update([w(1), w(2), w(3), w(4)]);
    expect(tabs.current, 2);
    tabs.select(3);
    tabs.update([w(1), w(2), w(4, focused: true)]);
    // The current one went: the focused one takes over, before the most recently used.
    expect(tabs.current, 4);
    tabs.update([w(1), w(2)]);
    expect(tabs.current, 2);
    tabs.update([w(5)]);
    expect(tabs.current, 5);
  });

  test('popupsFor keeps popups of the current window, or of a missing parent', () {
    final all = [
      w(1),
      w(2),
      w(5, kind: WindowKind.menu, parent: 2),
      w(6, kind: WindowKind.sheet, parent: 1),
      w(7, kind: WindowKind.popover, parent: 99),
      w(8, kind: WindowKind.tooltip),
    ];
    expect(popupsFor(all, 1).map((e) => e.id), [6, 7, 8]);
    expect(popupsFor(all, 2).map((e) => e.id), [5, 7, 8]);
  });
}
