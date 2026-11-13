import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/resources_tab.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late FakeTransport t;
  late FakeSessionPort port;
  late MainState s;
  late Directory tmp;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  Future<void> boot(WidgetTester tester) async {
    tmp = Directory.systemTemp.createTempSync('resources_tab_test');
    t = FakeTransport();
    port = FakeSessionPort();
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await tester.runAsync(flush);
    s = MainState(
      hub: HubClient(t),
      configDir: tmp.path,
      prefs: UiPrefs(),
      port: port,
      clock: () => DateTime(2026, 11, 12, 9, 5),
    );
    t.onSend = (m) {
      if (m['cmd'] == 'open') {
        t.emit({
          'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
          if (m['embed'] == true) ...{'port': 5001, 'token': 'tk'},
          'req': m['req'],
        });
      }
    };
    s.openOrSwitch('111', 'calc', 'Calculator');
    await tester.runAsync(flush);
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(wrap(SizedBox(width: 720, height: 2000, child: ResourcesTab(state: s))));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(flush);
    await tester.pump();
  }

  bool called(String name, Map<String, Object?> args) =>
      port.calls.any((c) => c.$1 == name && const DeepCollectionEquality().equals(c.$2, args));

  Finder inside(String key, Finder f) => find.descendant(of: find.byKey(Key(key)), matching: f);

  testWidgets('resources tab lists clips with kind, source and time', (tester) async {
    await boot(tester);
    port.emit(const ClipsEvent(1, [ClipRow(2, 'pic', true, ClipKind.image), ClipRow(1, 'hi', true, ClipKind.text)]));
    await show(tester);
    await settle(tester);
    expect(find.byKey(const Key('clip-1')), findsOneWidget);
    expect(find.byKey(const Key('clip-2')), findsOneWidget);
    expect(find.text('Calculator @ mini · 09:05'), findsNWidgets(2));
    expect(find.text('文字'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
  });

  testWidgets('kind tags use the design language borders', (tester) async {
    await boot(tester);
    await tester.pumpWidget(wrap(const Column(mainAxisSize: MainAxisSize.min, children: [
      KindTag(ClipKind.text, key: Key('k-text')),
      KindTag(ClipKind.image, key: Key('k-image')),
      KindTag(ClipKind.files, key: Key('k-files')),
    ])));
    int borders(String key) => find
        .descendant(of: find.byKey(Key(key)), matching: find.byType(DecoratedBox))
        .evaluate()
        .where((e) => ((e.widget as DecoratedBox).decoration as BoxDecoration).border != null)
        .length;
    bool dashed(String key) => find
        .descendant(of: find.byKey(Key(key)), matching: find.byType(CustomPaint))
        .evaluate()
        .any((e) => (e.widget as CustomPaint).painter is DashedOutline);
    expect(borders('k-text'), 1);
    expect(dashed('k-text'), isFalse);
    expect(dashed('k-image'), isTrue);
    expect(borders('k-image'), 0);
    expect(borders('k-files'), 2);
  });

  testWidgets('copy button greys with the reason', (tester) async {
    await boot(tester);
    port.emit(const ClipsEvent(1, [ClipRow(2, 'dir', false), ClipRow(1, 'hi', true)]));
    await show(tester);
    await settle(tester);
    // Entry seqs: 1 = clip 1 ('hi'), 2 = clip 2 ('dir').
    expect(inside('copy-2', find.text('不支持')), findsOneWidget);
    expect(inside('copy-1', find.text('复制到本机')), findsOneWidget);
    await tester.tap(find.byKey(const Key('copy-1')));
    await settle(tester);
    expect(called('clip_pick', {'sid': 1, 'clip': 1, 'insert': false}), isTrue);

    port.emit(const DisconnectedEvent(1, 'link lost'));
    await settle(tester);
    expect(inside('copy-1', find.text('A 已断开，复制不到')), findsOneWidget);
    final before = port.calls.length;
    await tester.tap(find.byKey(const Key('copy-1')), warnIfMissed: false);
    await settle(tester);
    expect(port.calls.length, before);
  });

  testWidgets('pin toggles the label', (tester) async {
    await boot(tester);
    port.emit(const ClipsEvent(1, [ClipRow(1, 'hi', true)]));
    await show(tester);
    await settle(tester);
    expect(inside('pin-1', find.text('固定')), findsOneWidget);
    await tester.tap(find.byKey(const Key('pin-1')));
    await settle(tester);
    expect(port.calls.any((c) => c.$1 == 'fetch_clip'), isTrue);
    expect(inside('pin-1', find.text('取消固定')), findsOneWidget);
  });

  testWidgets('running transfers show direction, percent and cancel', (tester) async {
    await boot(tester);
    port.emit(const TransferProgressEvent(1, 3, true, 'a.log', 10, 20, TransferState.running, null, null));
    await show(tester);
    await settle(tester);
    expect(find.text('↓ 从 A'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('a.log'), findsOneWidget);
    await tester.tap(find.byKey(const Key('cancel-1')));
    await settle(tester);
    expect(called('cancel_transfer', {'sid': 1, 'id': 3}), isTrue);
  });

  testWidgets('ended rows reveal downloads and show upload paths as text', (tester) async {
    await boot(tester);
    port.emit(const TransferProgressEvent(1, 3, true, 'a.log', 20, 20, TransferState.done, '/tmp/rapp-x/a.log', null));
    port.emit(const TransferProgressEvent(1, 4, false, 'b.txt', 5, 5, TransferState.done, null, null, kind: ClipKind.files));
    port.emit(const TransferProgressEvent(1, 5, true, 'c.bin', 1, 5, TransferState.failed, null, 'x'));
    await show(tester);
    await settle(tester);
    await tester.tap(find.byKey(const Key('reveal-1')));
    await settle(tester);
    expect(called('reveal', {'path': '/tmp/rapp-x/a.log'}), isTrue);
    expect(find.text('A：~/Downloads/rapp/b.txt'), findsOneWidget);
    expect(find.byKey(const Key('ended-2')), findsOneWidget);
    expect(find.byKey(const Key('reveal-2')), findsNothing);
    expect(find.byKey(const Key('reveal-3')), findsNothing);
    expect(find.text('没传完'), findsOneWidget);
  });

  testWidgets('upload rows name the file, and only a file upload says where it went on A', (tester) async {
    await boot(tester);
    // As the runner sends them (Transfers.swift): the file name, or empty with the kind.
    TransferProgressEvent up(int id, String name, String kind) => parseSessionEvent('transfer', {
          'sid': 1, 'id': id, 'dir': 'up', 'name': name, 'kind': kind, 'done': 5, 'total': 5, 'state': 'done',
        }) as TransferProgressEvent;
    port.emit(up(4, 'report.pdf', 'files'));
    port.emit(up(5, '', 'image'));
    port.emit(up(6, '', 'text'));
    await show(tester);
    await settle(tester);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('A：~/Downloads/rapp/report.pdf'), findsOneWidget);
    expect(find.textContaining('A：'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('文字'), findsOneWidget);
  });

  testWidgets('the same sid and id after a hub restart make two rows, not a key clash', (tester) async {
    await boot(tester);
    port.emit(const TransferProgressEvent(1, 3, true, 'a.log', 20, 20, TransferState.done, '/tmp/rapp-x/a.log', null));
    s.endCurrent();
    port.emit(const ClosedEvent(1, 'rapp-client: quit'));
    s.openOrSwitch('111', 'calc', 'Calculator'); // the restarted hub hands out sid 1 again
    await tester.runAsync(flush);
    port.emit(const TransferProgressEvent(1, 3, true, 'b.log', 20, 20, TransferState.done, '/tmp/rapp-x/b.log', null));
    await show(tester);
    await settle(tester);
    expect(find.byKey(const Key('ended-1')), findsOneWidget);
    expect(find.byKey(const Key('ended-2')), findsOneWidget);
    await tester.tap(find.byKey(const Key('reveal-2')));
    await settle(tester);
    expect(called('reveal', {'path': '/tmp/rapp-x/b.log'}), isTrue);
  });

  testWidgets('empty sections say so', (tester) async {
    await boot(tester);
    await show(tester);
    expect(find.text('还没有剪贴板条目'), findsOneWidget);
    expect(find.text('没有进行中的传输'), findsOneWidget);
    expect(find.text('这次启动还没有传过文件'), findsOneWidget);
  });

  testWidgets('all controls are at least 48 tall', (tester) async {
    await boot(tester);
    port.emit(const ClipsEvent(1, [ClipRow(1, 'hi', true)]));
    port.emit(const TransferProgressEvent(1, 3, true, 'a.log', 10, 20, TransferState.running, null, null));
    port.emit(const TransferProgressEvent(1, 4, true, 'd.log', 20, 20, TransferState.done, '/tmp/d.log', null));
    await show(tester);
    await settle(tester);
    final buttons = find.byType(RappButton);
    expect(buttons.evaluate().length, greaterThanOrEqualTo(4));
    for (final e in buttons.evaluate()) {
      expect(tester.getSize(find.byWidget(e.widget)).height, greaterThanOrEqualTo(48));
    }
    for (final e in find.byType(InkWell).evaluate()) {
      expect(tester.getSize(find.byWidget(e.widget)).height, greaterThanOrEqualTo(48));
    }
  });
}
