import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/window_tabs.dart';

RemoteWindow w(int id, {WindowKind kind = WindowKind.normal, int parent = 0}) => RemoteWindow(
      id: id,
      parent: parent,
      kind: kind,
      title: 'w$id',
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      titleBar: 28,
      resizable: true,
      focused: false,
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
