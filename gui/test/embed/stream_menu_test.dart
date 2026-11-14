// ignore: depend_on_referenced_packages
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/stream_choice.dart';
import 'package:rapp/embed/stream_menu.dart';
import 'package:rapp/ui/resources_state.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

void main() {
  late FakeSessionPort port;
  late RemoteSession rs;
  var ended = 0;
  var shellOpen = false;
  int? detachCalls;
  var disconnects = 0, reconnects = 0;
  late ResourcesState res;
  final copied = <int>[];
  var allClips = 0;
  var remembered = 0, profileOpened = 0;
  var greyClip = -1;
  var marks = 0, clears = 0;
  var routeToggles = 0;

  bool called(String name, Map<String, Object?> args) =>
      port.calls.any((c) => c.$1 == name && const DeepCollectionEquality().equals(c.$2, args));

  Future<void> open(WidgetTester tester,
      {VoidCallback? onDetach, bool disconnected = false, bool reconnecting = false, bool hub = true, String status = '活动', String reconnectWord = '重连',
      List<int> seed = const [], Object seedSid = 1, int? other, int grey = -1, Set<MenuPart> parts = allMenuParts,
      bool? forcedRelay, bool route = true, String path = 'lan'}) async {
    shellOpen = false;
    routeToggles = 0;
    ended = 0;
    disconnects = 0;
    reconnects = 0;
    copied.clear();
    allClips = 0;
    remembered = 0;
    profileOpened = 0;
    greyClip = grey;
    res = ResourcesState(clock: () => DateTime(2026, 11, 12, 9, 5));
    addTearDown(res.dispose);
    if (seed.isNotEmpty) res.addClips('k', seedSid, 'Calc @ mini', [for (final i in seed.reversed) ClipRow(i, 'clip $i', true)]);
    if (other != null) res.addClips('other', 2, 'Notes @ mini', [ClipRow(other, 'clip $other', true)]);
    port = FakeSessionPort();
    rs = RemoteSession(1, 'Calc', onStream: (c) => port.setStream(1, c.mode, c.fps, c.density));
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(Align(
      alignment: Alignment.topRight,
      child: StatefulBuilder(builder: (context, set) => StreamMenuAnchor(
        open: shellOpen,
        onToggle: () => set(() => shellOpen = !shellOpen),
        onClose: () => set(() => shellOpen = false),
        port: port,
        session: rs,
        path: path,
        status: status,
        disconnected: disconnected,
        reconnecting: reconnecting,
        reconnectWord: reconnectWord,
        onDisconnect: hub ? () => disconnects++ : null,
        onReconnect: hub ? () => reconnects++ : null,
        onEnd: () => ended++,
        onToggleDetach: onDetach,
        onRememberStream: () => remembered++,
        onOpenProfile: () => profileOpened++,
        forcedRelay: forcedRelay,
        onToggleRoute: route ? () => routeToggles++ : null,
        clips: res.clipsOf('k'),
        canCopy: (e) => e.clip != greyClip,
        canInsert: (e) => e.clip != greyClip && e.sid == rs.sid,
        onCopy: (e) => copied.add(e.clip),
        onAllClips: () => allClips++,
        onMarkInput: () => marks++,
        onClearInput: () => clears++,
        parts: parts,
      )),
    )));
    final kind = parts.contains(MenuPart.stream) ? 'traffic' : (parts.contains(MenuPart.remote) ? 'remote-menu' : 'session-menu');
    await tester.tap(find.byKey(Key(kind)));
    await tester.pump();
  }

  testWidgets('session group shows status and disconnect', (tester) async {
    await open(tester);
    expect(find.text('路径 局域网 · 活动'), findsOneWidget);
    await tester.ensureVisible(find.text('断开'));
    await tester.tap(find.text('断开'));
    await tester.pump();
    expect(disconnects, 1);
    expect(find.text('路径 局域网 · 活动'), findsNothing); // closed
  });

  testWidgets('the route item says 改走中继 or 恢复自动选路, and is absent without a relay', (tester) async {
    await open(tester);
    expect(find.text('改走中继'), findsNothing);
    expect(find.text('恢复自动选路'), findsNothing);
    await open(tester, forcedRelay: false);
    expect(find.text('改走中继'), findsOneWidget);
    expect(find.text('恢复自动选路'), findsNothing);
    await open(tester, forcedRelay: true);
    expect(find.text('恢复自动选路'), findsOneWidget);
    expect(find.text('改走中继'), findsNothing);
  });

  testWidgets('a forced relay path reads 中继（强制）', (tester) async {
    await open(tester, forcedRelay: true);
    expect(find.text('路径 局域网 · 活动'), findsOneWidget); // forced, but this session is still on the LAN
    await open(tester, forcedRelay: true, path: 'relay');
    expect(find.text('路径 中继（强制） · 活动'), findsOneWidget);
    await open(tester, forcedRelay: false, path: 'relay');
    expect(find.text('路径 中继 · 活动'), findsOneWidget);
  });

  testWidgets('the route item calls back once and closes the menu', (tester) async {
    await open(tester, forcedRelay: false);
    await tester.ensureVisible(find.text('改走中继'));
    await tester.tap(find.text('改走中继'));
    await tester.pump();
    expect(routeToggles, 1);
    expect(find.text('改走中继'), findsNothing); // closed
  });

  testWidgets('the route item is greyed without a callback', (tester) async {
    await open(tester, forcedRelay: true, route: false);
    await tester.ensureVisible(find.text('恢复自动选路'));
    await tester.tap(find.text('恢复自动选路'));
    await tester.pump();
    expect(routeToggles, 0);
    expect(find.text('恢复自动选路'), findsOneWidget); // still open
  });

  testWidgets('no route item while reconnecting; a disconnected session keeps it', (tester) async {
    await open(tester, reconnecting: true, status: '连接中', forcedRelay: false);
    expect(find.text('改走中继'), findsNothing);
    await open(tester, disconnected: true, forcedRelay: false);
    expect(find.text('改走中继'), findsOneWidget);
  });

  testWidgets('disconnected menu keeps only the session group with reconnect', (tester) async {
    await open(tester, disconnected: true);
    expect(find.text('重连'), findsOneWidget);
    expect(find.text('结束会话'), findsOneWidget);
    expect(find.text('路径 局域网 · 活动'), findsOneWidget);
    for (final gone in ['断开', '高彩（图像优化）', '分离成独立窗口', '放左上角', '预设', '远程剪贴板']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    await tester.tap(find.text('重连'));
    await tester.pump();
    expect(reconnects, 1);
    expect(find.text('重连'), findsNothing); // closed
  });

  testWidgets('a taken-over session offers 拿回来 instead of 重连 (R13)', (tester) async {
    await open(tester, disconnected: true, reconnectWord: '拿回来');
    expect(find.text('重连'), findsNothing);
    await tester.tap(find.text('拿回来'));
    await tester.pump();
    expect(reconnects, 1);
  });

  testWidgets('a reconnecting session gets the reduced menu without 重连', (tester) async {
    await open(tester, reconnecting: true, status: '连接中');
    expect(find.text('路径 局域网 · 连接中'), findsOneWidget);
    expect(find.text('结束会话'), findsOneWidget);
    for (final gone in ['重连', '断开', '分离成独立窗口', '放左上角', '预设', '远程剪贴板']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
  });

  testWidgets('断开 and 重连 are greyed without a hub', (tester) async {
    await open(tester, hub: false);
    await tester.ensureVisible(find.text('断开'));
    await tester.tap(find.text('断开'));
    await tester.pump();
    expect(disconnects, 0);
    expect(find.text('路径 局域网 · 活动'), findsOneWidget); // still open: nothing was picked
  });

  testWidgets('重连 is greyed without a hub', (tester) async {
    await open(tester, disconnected: true, hub: false);
    await tester.tap(find.text('重连'));
    await tester.pump();
    expect(reconnects, 0);
    expect(find.text('路径 局域网 · 活动'), findsOneWidget);
  });

  const preset = '最省流（双色·灰度 + 自适应 + 1 fps）';

  testWidgets('picking a preset sets stream and closes the menu', (tester) async {
    await open(tester);
    await tester.tap(find.text(preset));
    await tester.pump();
    expect(called('set_stream', {'sid': 1, 'mode': 'duogray', 'fps': 1, 'density': 'adaptive'}), isTrue);
    expect(rs.choice, presetLeast);
    expect(find.text(preset), findsNothing);
  });

  testWidgets('the current choice is ticked; picking one group keeps the others', (tester) async {
    await open(tester);
    expect(rs.choice, const StreamChoice('color16', 'adaptive', 15));
    expect(find.byIcon(Icons.check), findsNWidgets(3)); // mode, density, fps
    await tester.tap(find.text('原画'));
    await tester.pump();
    expect(called('set_stream', {'sid': 1, 'mode': 'color16', 'fps': 15, 'density': 'original'}), isTrue);
  });

  testWidgets('group five shows the session\'s two newest from the global list', (tester) async {
    await open(tester, seed: [1, 2, 3], other: 9);
    expect(find.text('clip 3'), findsOneWidget);
    expect(find.text('clip 2'), findsOneWidget);
    expect(find.text('clip 1'), findsNothing);
    expect(find.text('clip 9'), findsNothing);
    expect(find.text('（空）'), findsNothing);
  });

  testWidgets('empty group says so and has no all-clips item', (tester) async {
    await open(tester);
    expect(find.text('（空）'), findsOneWidget);
    expect(find.text('全部剪贴板'), findsNothing);
  });

  testWidgets('tapping an entry copies and closes; insert picks on the live session', (tester) async {
    await open(tester, seed: [1, 2]);
    await tester.ensureVisible(find.text('clip 2'));
    await tester.tap(find.text('clip 2'));
    await tester.pump();
    expect(copied, [2]);
    expect(find.text('全部剪贴板'), findsNothing); // closed
    await tester.tap(find.byKey(const Key('traffic')));
    await tester.pump();
    expect(find.text('插入'), findsNWidgets(2));
    await tester.ensureVisible(find.text('插入').first);
    await tester.tap(find.text('插入').first);
    await tester.pump();
    expect(called('clip_pick', {'sid': 1, 'clip': 2, 'insert': true}), isTrue);
    expect(copied, [2]);
  });

  testWidgets('an entry of an older session has no insert button', (tester) async {
    await open(tester, seed: [1], seedSid: 7);
    expect(find.text('clip 1'), findsOneWidget);
    expect(find.text('插入'), findsNothing);
  });

  testWidgets('all clips opens the resources tab and closes the menu', (tester) async {
    await open(tester, seed: [1]);
    await tester.ensureVisible(find.text('全部剪贴板'));
    await tester.tap(find.text('全部剪贴板'));
    await tester.pump();
    expect(allClips, 1);
    expect(find.text('全部剪贴板'), findsNothing);
  });

  testWidgets('a grey entry is not tappable and has no insert', (tester) async {
    await open(tester, seed: [1, 2], grey: 2);
    expect(find.text('插入'), findsOneWidget);
    await tester.ensureVisible(find.text('clip 2'));
    await tester.tap(find.text('clip 2'), warnIfMissed: false);
    await tester.pump();
    expect(copied, isEmpty);
    expect(find.text('clip 2'), findsOneWidget); // menu stays
  });

  testWidgets('end session needs two taps', (tester) async {
    await open(tester);
    await tester.ensureVisible(find.text('结束会话'));
    await tester.tap(find.text('结束会话'));
    await tester.pump();
    expect(ended, 0);
    await tester.tap(find.text('再点一次确认'));
    await tester.pump();
    expect(ended, 1);
    expect(find.text(preset), findsNothing);
  });

  testWidgets('move to top-left needs a current window; detach is greyed without a callback', (tester) async {
    await open(tester);
    await tester.ensureVisible(find.text('放左上角'));
    await tester.tap(find.text('放左上角'));
    await tester.pump();
    expect(port.calls.where((c) => c.$1 == 'move_top_left'), isEmpty);
    expect(find.text(preset), findsOneWidget); // disabled: menu stays
    await tester.tap(find.text('分离成独立窗口'));
    await tester.pump();
    expect(port.calls.where((c) => c.$1 == 'detach'), isEmpty);
    expect(find.text(preset), findsOneWidget);
    expect(detachCalls, isNull);
  });

  testWidgets('move to top-left sends the current window', (tester) async {
    await open(tester);
    rs.apply(WindowsEvent(1, [
      RemoteWindow(
          id: 7, parent: 0, kind: WindowKind.normal, title: 't', rect: const Rect.fromLTWH(0, 0, 10, 10),
          titleBar: 0, resizable: true, focused: true, texture: 1, visible: const Rect.fromLTWH(0, 0, 1, 1)),
    ]));
    await tester.pump();
    await tester.ensureVisible(find.text('放左上角'));
    await tester.tap(find.text('放左上角'));
    await tester.pump();
    expect(called('move_top_left', {'sid': 1, 'window': 7}), isTrue);
    expect(find.text(preset), findsNothing);
  });

  testWidgets('detach item calls back when given one', (tester) async {
    var n = 0;
    await open(tester, onDetach: () => n++);
    await tester.ensureVisible(find.text('分离成独立窗口'));
    await tester.tap(find.text('分离成独立窗口'));
    await tester.pump();
    expect(n, 1);
    expect(find.text(preset), findsNothing);
  });

  testWidgets('stream menu offers detach or attach by state', (tester) async {
    var n = 0;
    await open(tester, onDetach: () => n++);
    await tester.ensureVisible(find.text('分离成独立窗口'));
    expect(find.text('放回主窗口'), findsNothing);
    rs.apply(const DetachedEvent(1, true));
    await tester.pump();
    expect(find.text('分离成独立窗口'), findsNothing);
    await tester.ensureVisible(find.text('放回主窗口'));
    await tester.tap(find.text('放回主窗口'));
    await tester.pump();
    expect(n, 1);
    expect(find.text(preset), findsNothing);
  });

  testWidgets('the remote menu drills down and picks by path', (tester) async {
    await open(tester);
    rs.apply(const MenuEvent(1, [
      MenuEntry(title: '文件', children: [
        MenuEntry(title: '新建', shortcut: '⌘N'),
        MenuEntry(title: '', separator: true),
        MenuEntry(title: '关闭'),
      ]),
    ]));
    await tester.pump();
    await tester.ensureVisible(find.text('文件'));
    await tester.tap(find.text('文件'));
    await tester.pump();
    expect(find.text('⌘N'), findsOneWidget);
    await tester.ensureVisible(find.text('关闭'));
    await tester.tap(find.text('关闭'));
    await tester.pump();
    expect(called('menu_pick', {'sid': 1, 'path': [0, 2]}), isTrue);
    expect(find.text(preset), findsNothing);
  });

  testWidgets('top level of A menu skips separators and untitled, never picks a leaf; indices count them', (tester) async {
    await open(tester);
    rs.apply(const MenuEvent(1, [
      MenuEntry(title: '', separator: true),
      MenuEntry(title: '空标题', children: []),
      MenuEntry(title: '编辑', children: [MenuEntry(title: '复制')]),
      MenuEntry(title: '', children: [MenuEntry(title: 'x')]),
    ]));
    await tester.pump();
    await tester.ensureVisible(find.text('空标题'));
    await tester.tap(find.text('空标题'), warnIfMissed: false);
    await tester.pump();
    expect(port.calls.where((c) => c.$1 == 'menu_pick'), isEmpty);
    expect(find.text('x'), findsNothing);
    await tester.ensureVisible(find.text('编辑'));
    await tester.tap(find.text('编辑'));
    await tester.pump();
    await tester.ensureVisible(find.text('复制'));
    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(called('menu_pick', {'sid': 1, 'path': [2, 0]}), isTrue);
  });

  testWidgets('记为这个 app 的默认 and app 配置… call back and close the menu', (tester) async {
    await open(tester);
    await tester.ensureVisible(find.text('记为这个 app 的默认'));
    await tester.tap(find.text('记为这个 app 的默认'));
    await tester.pump();
    expect(remembered, 1);
    expect(shellOpen, isFalse);
    await tester.tap(find.byKey(const Key('traffic')));
    await tester.pump();
    await tester.ensureVisible(find.text('app 配置…'));
    await tester.tap(find.text('app 配置…'));
    await tester.pump();
    expect(profileOpened, 1);
  });

  testWidgets('a disconnected menu has neither item', (tester) async {
    await open(tester, disconnected: true);
    expect(find.text('记为这个 app 的默认'), findsNothing);
    expect(find.text('app 配置…'), findsNothing);
  });

  group('split menus', () {
    testWidgets('本机 has the session, clipboard, input method and input box; no stream or remote items', (tester) async {
      await open(tester, parts: {MenuPart.session}, seed: [2]);
      expect(find.byKey(const Key('session-menu-scrim')), findsOneWidget);
      expect(find.text('结束会话'), findsOneWidget);
      expect(find.text('远程剪贴板'), findsOneWidget);
      expect(find.text(preset), findsNothing);
      expect(find.text('远程菜单'), findsNothing);
      expect(find.text('远端输入法'), findsNothing); // the host never said
      rs.apply(const InputSourceEvent(1, 'im', '拼音', false));
      await tester.pump();
      expect(find.text('现在：拼音'), findsOneWidget);
      await tester.ensureVisible(find.text('切到英文'));
      await tester.tap(find.text('切到英文'));
      await tester.pump();
      expect(shellOpen, isFalse);
      await tester.tap(find.byKey(const Key('session-menu')));
      await tester.pump();
      await tester.ensureVisible(find.text('标记输入区（再点一下画面）'));
      await tester.tap(find.text('标记输入区（再点一下画面）'));
      await tester.pump();
      expect(marks, 1);
    });

    testWidgets('远程 shows only the app menu', (tester) async {
      await open(tester, parts: {MenuPart.remote});
      expect(find.byKey(const Key('remote-menu-scrim')), findsOneWidget);
      expect(find.text('远端 app 还没有菜单'), findsOneWidget);
      rs.apply(const MenuEvent(1, [MenuEntry(title: '文件')]));
      await tester.pump();
      expect(find.text('Calc 的菜单'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);
      expect(find.text('结束会话'), findsNothing);
      expect(find.text(preset), findsNothing);
    });

    testWidgets('流量优化 alone has no session items', (tester) async {
      await open(tester, parts: {MenuPart.stream});
      expect(find.text(preset), findsOneWidget);
      expect(find.text('结束会话'), findsNothing);
      expect(find.text('远程剪贴板'), findsNothing);
    });
  });
}
