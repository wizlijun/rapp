import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/key_bar.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/term/term_model.dart';
import 'package:rapp/term/term_session_port.dart';
import 'package:rapp/term/term_stage.dart';
import 'package:rapp/term/term_wire.dart';
import 'package:rapp/ui/controls.dart' show RappButton;
import 'package:rapp/ui/disconnected_stage.dart';
import 'package:rapp/ui/lifecycle.dart' show Phase;
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/sessions_tab.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/top_bar.dart';
import 'package:rapp/ui/workspace_store.dart' show AppRef;

import '../fakes.dart';
import '../ui/helpers.dart';

const app = 'term:pty:work';

TermPane tp(int n, String command, {String title = '', bool active = false, bool dead = false, String win = '@1'}) =>
    TermPane(
      id: '%$n',
      win: win,
      window: win,
      title: title,
      command: command,
      cols: 80,
      rows: 24,
      dead: dead,
      active: active,
    );

/// The window table the port makes of [panes].
WindowsEvent windowsOf(Object sid, List<TermPane> panes) {
  final labels = tabLabels(panes);
  return WindowsEvent(sid, [
    for (final p in panes)
      RemoteWindow(
        id: p.number,
        parent: 0,
        kind: WindowKind.normal,
        title: labels[p.id]!,
        rect: Rect.zero,
        titleBar: 0,
        resizable: false,
        focused: p.active,
        texture: null,
        visible: Rect.zero,
      ),
  ]);
}

void main() {
  late FakeTransport t;
  late HubClient hub;
  late Directory tmp;
  late FakeSessionPort port;
  late FakeTermSessionPort term;
  late MainState s;
  var nextSid = 1;

  Future<void> flush() => Future<void>.delayed(Duration.zero);
  int opens() => t.sent.where((m) => m['cmd'] == 'open').length;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('term_main_test');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await flush();
    nextSid = 1;
    t.onSend = (m) {
      if (m['cmd'] == 'open') {
        t.emit({
          'event': 'opened', 'sid': nextSid++, 'id': m['id'], 'app': m['app'], 'path': 'lan',
          'port': 5001, 'token': 'tk', 'req': m['req'],
        });
      }
    };
    port = FakeSessionPort();
    term = FakeTermSessionPort();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: term);
  });

  tearDown(() {
    s.dispose();
    term.dispose();
    tmp.deleteSync(recursive: true);
  });

  Widget window({double width = 1200}) => SizedBox(
        width: width,
        height: 700,
        child: Column(children: [
          TopBar(state: s, fullscreen: false, onToggleFullscreen: () {}),
          Expanded(child: Stage(state: s)),
        ]),
      );

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    await tester.pump();
  }

  Future<void> openTerm(WidgetTester tester, List<TermPane> panes, {String id = app}) async {
    term.paneLists[1] = panes;
    await tester.runAsync(() async {
      s.openOrSwitch('111', id, 'work');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    term.play(const ReadyEvent(1, 'claude'));
    term.play(windowsOf(1, panes));
    // The port counts a screen as a frame: the lamp goes from connecting to live.
    term.play(const TrafficEvent(1, 0, 1));
    await settle(tester);
  }

  final two = [tp(3, 'claude', title: 'build-box', active: true), tp(4, 'logs', title: 'tail')];

  testWidgets('opening a terminal goes through the terminal port and shows TermStage', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    final open = t.sent.where((m) => m['cmd'] == 'open').single;
    expect((open['app'], open['embed']), (app, true));
    expect(term.calls.where((c) => c.$1 == 'start').single.$2['sid'], 1);
    expect(port.calls.where((c) => c.$1 == 'start'), isEmpty);
    expect(find.byType(TermStage), findsOneWidget);
    // The control names the current pane; the others are in its menu.
    expect(tester.widget<Text>(find.byKey(const Key('window-menu-label'))).data, 'claude');
    await tester.tap(find.byKey(const Key('window-menu')));
    await settle(tester);
    expect(find.text('logs'), findsOneWidget);
    // A pane has no × and no window rules.
    expect(find.byKey(const Key('close-window-4')), findsNothing);
    await tester.tap(find.byKey(const Key('window-row-4')), buttons: kSecondaryButton);
    await settle(tester);
    expect(find.text('隐藏这类窗口'), findsNothing);
    // The device's current pane is the first tab, and it is viewed.
    expect(s.currentRemote!.currentWindow, 3);
    expect(term.calls.where((c) => c.$1 == 'view').last.$2['window'], 3);
  });

  testWidgets('app-session calls for a terminal sid never reach the native port', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    s.selectWindow(4);
    s.focusPicture(1);
    s.closeWindow(4);
    s.endCurrent();
    await settle(tester);
    expect(port.calls.where((c) => c.$2['sid'] == 1), isEmpty);
    expect(term.calls.where((c) => c.$1 == 'close').single.$2['sid'], 1);
  });

  void termsEvent(String name, {String? fg}) => t.emit({
        'event': 'terms',
        'id': '111',
        'terms': [
          {'id': app, 'host': null, 'name': name, 'command': 'claude', 'panes': 1, 'attached': 1, 'activity': 0,
           'dead': false, 'unread': false, 'fg': ?fg},
        ],
        'hosts': [
          {'host': null},
        ],
      });

  testWidgets('the top bar says CLI · zsh', (tester) async {
    termsEvent('zsh');
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    expect(find.text('CLI · zsh'), findsOneWidget);
    // No pane command prefix and no pane title in the second line.
    expect(find.text('claude · zsh'), findsNothing);
    expect(find.text('mini · 局域网'), findsOneWidget);
    expect(s.current!.title, 'CLI · zsh');
    await tester.pumpWidget(wrap(SizedBox(width: 330, height: 400, child: SessionsTab(state: s))));
    expect(find.text('CLI · zsh'), findsOneWidget);
  });

  testWidgets('the title names the program in front, and the line under it says CLI', (tester) async {
    termsEvent('zsh', fg: 'claude');
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    expect(s.current!.title, 'claude · zsh');
    expect(find.text('claude · zsh'), findsOneWidget);
    expect(find.text('CLI · mini · 局域网'), findsOneWidget);
    // The program changes: the title follows it.
    termsEvent('zsh', fg: 'codex');
    await settle(tester);
    expect(find.text('codex · zsh'), findsOneWidget);
    expect(s.labelOf(AppRef('111', app, 'zsh')), 'codex · zsh');
    await tester.pumpWidget(wrap(SizedBox(width: 330, height: 400, child: SessionsTab(state: s))));
    expect(find.text('codex · zsh'), findsOneWidget);
    expect(find.text('CLI · 局域网'), findsOneWidget);
  });

  testWidgets('the title follows a rename', (tester) async {
    termsEvent('zsh');
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    expect(find.text('CLI · zsh'), findsOneWidget);
    termsEvent('后端');
    await settle(tester);
    expect(find.text('CLI · 后端'), findsOneWidget);
    expect(find.text('CLI · zsh'), findsNothing);
    // The row is gone from the list: the last name seen stays.
    t.emit({'event': 'terms', 'id': '111', 'terms': [], 'hosts': [{'host': null}]});
    await settle(tester);
    expect(find.text('CLI · 后端'), findsOneWidget);
  });

  testWidgets('a favorite of a terminal is labelled CLI ·', (tester) async {
    termsEvent('zsh');
    s.toggleFavorite('111', app, 'zsh');
    await tester.pumpWidget(wrap(SizedBox(width: 330, height: 400, child: SessionsTab(state: s))));
    expect(find.text('CLI · zsh'), findsOneWidget);
    termsEvent('后端');
    await tester.pump();
    expect(find.text('CLI · 后端'), findsOneWidget);
  });

  testWidgets('the traffic menu of a terminal has no refit and no stream presets', (tester) async {
    // Narrow: the traffic label carries every part of the menu.
    await tester.pumpWidget(wrap(window(width: 500)));
    await openTerm(tester, two);
    await tester.tap(find.byKey(const Key('traffic')));
    await tester.pumpAndSettle();
    expect(find.text('按我的屏幕重排'), findsNothing);
    expect(find.byKey(const Key('term-refit')), findsNothing);
    for (final gone in ['预设', '分离成独立窗口', '放左上角', '远程剪贴板', '输入区', 'app 配置…', '远程菜单']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    expect(find.text('会话'), findsOneWidget);
    expect(find.text('关闭'), findsWidgets);
  });

  testWidgets('a pane larger than the stage says nothing about being scaled', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    term.models[1]!
      ..expect('%3')
      ..apply(TermScreen(
          pane: '%3', rev: 1, cols: 300, rows: 90, cx: 0, cy: 0, cursor: true, alt: false, full: true, more: false,
          lines: [for (var i = 0; i < 90; i++) (i, 'row $i')]));
    await settle(tester);
    expect(find.byKey(const Key('term-scaled')), findsNothing);
  });

  testWidgets('a wide bar shows no remote menu button for a terminal', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    expect(find.byKey(const Key('session-menu')), findsOneWidget);
    expect(find.byKey(const Key('remote-menu')), findsNothing);
  });

  testWidgets('the current pane closing moves to another pane and views it', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    expect(s.currentRemote!.currentWindow, 3);
    term.calls.clear();
    term.paneLists[1] = [tp(4, 'logs', active: true)];
    term.play(windowsOf(1, term.paneLists[1]!));
    await settle(tester);
    expect(s.currentRemote!.currentWindow, 4);
    expect(term.calls.where((c) => c.$1 == 'view').single.$2['window'], 4);
    expect(find.byType(TermStage), findsOneWidget);
  });

  testWidgets('a terminal has no plus for a new window', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, [tp(3, 'claude', active: true)]);
    expect(find.byKey(const Key('window-menu')), findsOneWidget);
    expect(find.byKey(const Key('term-new-window')), findsNothing);
    expect(find.text('＋'), findsNothing);
  });

  testWidgets('a new pane does not take over the current tab', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    term.paneLists[1] = [...two, tp(5, 'htop', win: '@2')];
    term.play(windowsOf(1, term.paneLists[1]!));
    await settle(tester);
    expect(s.currentRemote!.currentWindow, 3);
    await tester.tap(find.byKey(const Key('window-menu')));
    await settle(tester);
    expect(find.text('htop'), findsOneWidget);
  });

  testWidgets('a dead pane keeps its screen and says so on the tab', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    term.paneLists[1] = [tp(3, 'claude', active: true, dead: true), tp(4, 'logs')];
    term.play(windowsOf(1, term.paneLists[1]!));
    await settle(tester);
    expect(tester.widget<Text>(find.byKey(const Key('window-menu-label'))).data, 'claude · 已退出');
    expect(find.byType(TermStage), findsOneWidget);
    expect(s.currentRemote!.currentWindow, 3);
  });

  Future<void> drop(WidgetTester tester) async {
    term.play(const DisconnectedEvent(1, 'connection closed'));
    await settle(tester);
  }

  testWidgets('a network drop keeps the terminal on the stage with a bar', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    await drop(tester);
    expect(find.byType(TermStage), findsOneWidget);
    expect(find.byType(DisconnectedStage), findsNothing);
    expect(find.byKey(const Key('offline-bar')), findsOneWidget);
    expect(find.byKey(const Key('composer-open')), findsOneWidget);
  });

  testWidgets('a frozen terminal sends no keys, text or paste, but still copies', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      if (call.method == 'Clipboard.getData') return {'text': 'ls'};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    term.models[1] = TermModel()
      ..expect('%3')
      ..apply(TermScreen(
          pane: '%3', rev: 1, cols: 40, rows: 8, cx: 0, cy: 0, cursor: true, alt: false, full: true, more: false,
          lines: [for (var i = 0; i < 8; i++) (i, 'abcdef')]));
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    await drop(tester);
    term.calls.clear();
    final grid = tester.getTopLeft(find.byKey(const Key('term-grid')));
    // The picture stands one key bar up, its top under the top bar: drag lower down.
    final g = await tester.startGesture(grid + const Offset(2, 220), kind: PointerDeviceKind.mouse);
    await g.moveTo(grid + const Offset(60, 220));
    await g.up();
    await tester.pump();
    expect(find.byKey(const Key('term-copy')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    await tester.sendKeyDownEvent(mac ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft);
    if (!mac) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    if (!mac) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(mac ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft);
    await tester.runAsync(() => flush());
    await tester.pump();
    expect(term.calls.where((c) => {'keys', 'type', 'paste'}.contains(c.$1)), isEmpty);
    await tester.sendKeyDownEvent(mac ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft);
    if (!mac) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    if (!mac) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(mac ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(seconds: 2));
    expect(copied, isNotEmpty);
    expect(copied.first, startsWith('a'));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS)..values.add(TargetPlatform.linux));

  testWidgets('a terminal has the KeyBar, no keyrow-* (iOS and the desktop)', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('keyrow-')),
        findsNothing);
    expect(find.byType(KeyBar), findsOneWidget);
  }, variant: TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.macOS}));

  testWidgets('a frozen key bar sends no keys', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    await tester.tap(find.byKey(const Key('composer-open')));
    await tester.pump();
    await tester.pump();
    await drop(tester);
    term.calls.clear();
    await tester.tap(find.byKey(const Key('bar-cc')));
    await tester.tap(find.byKey(const Key('bar-enter')));
    await tester.pump();
    await tester.pump();
    expect(term.calls.where((c) => {'keys', 'type', 'paste'}.contains(c.$1)), isEmpty);
  });

  testWidgets('a paste that read the clipboard before the drop sends nothing after it', (tester) async {
    final read = Completer<Map<String, Object?>>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return read.future;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    term.calls.clear();
    final rs = s.currentRemote!;
    final f = s.termPaste(rs);
    await drop(tester);
    read.complete({'text': 'rm -rf'});
    await tester.runAsync(() async {
      await f;
      await flush();
    });
    expect(term.calls.where((c) => {'keys', 'type', 'paste'}.contains(c.$1)), isEmpty);
  });

  testWidgets('the frozen terminal element survives the drop and the reconnect swaps in a live one', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    final before = tester.element(find.byType(TermStage));
    await drop(tester);
    expect(tester.element(find.byType(TermStage)), same(before));
    expect(tester.widget<TermStage>(find.byType(TermStage)).frozen, isTrue);
    term.calls.clear();
    term.paneLists[2] = two;
    await tester.runAsync(() async {
      s.reconnectCurrent();
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    term.play(windowsOf(2, two));
    await settle(tester);
    expect(find.byKey(const Key('offline-bar')), findsNothing);
    expect(tester.widget<TermStage>(find.byType(TermStage)).frozen, isFalse);
    final v = term.calls.where((c) => c.$1 == 'view').last.$2;
    expect((v['sid'], v['window']), (2, 3));
    expect(tester.element(find.byType(TermStage)), same(before));
  });

  testWidgets('a recovery does not pull the focus into the terminal', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    await drop(tester);
    await tester.tap(find.byKey(const Key('composer-open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // the text area grows in
    await tester.tap(find.byKey(const Key('composer-field')));
    await tester.pump();
    FocusNode? primary() => FocusManager.instance.primaryFocus;
    expect(primary()?.debugLabel, 'composer');
    final tick = s.termFocusTick;
    term.paneLists[2] = two;
    await tester.runAsync(() async {
      s.reconnectCurrent();
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    term.play(windowsOf(2, two));
    await settle(tester);
    expect(find.byKey(const Key('offline-bar')), findsNothing);
    expect(s.termFocusTick, tick); // the terminal was not asked for the keys
    expect(find.byKey(const Key('composer-panel')), findsOneWidget);
    expect(primary()?.debugLabel, isNot('term-stage'));
    expect(primary()?.debugLabel, 'composer');
  });

  testWidgets('a terminal that never showed a screen keeps the disconnected stage on a network drop', (tester) async {
    await tester.pumpWidget(wrap(window()));
    term.paneLists[1] = two;
    await tester.runAsync(() async {
      s.openOrSwitch('111', app, 'work');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    term.play(const ReadyEvent(1, 'claude'));
    term.play(const DisconnectedEvent(1, 'connection closed'));
    await settle(tester);
    expect(find.byType(DisconnectedStage), findsOneWidget);
    expect(find.byKey(const Key('offline-bar')), findsNothing);
  });

  testWidgets('a terminal whose first open failed for a network reason is not frozen once it reconnects', (tester) async {
    await tester.pumpWidget(wrap(window()));
    final ok = t.onSend;
    t.onSend = (m) {
      if (m['cmd'] == 'open') t.emit({'event': 'error', 'req': m['req'], 'error': 'cannot reach the host'});
    };
    await tester.runAsync(() async {
      s.openOrSwitch('111', app, 'work');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    expect(s.currentRecord!.phase, Phase.disconnected);
    expect(s.currentRecord!.frozen, isFalse);
    t.onSend = ok;
    term.paneLists[1] = two;
    await tester.runAsync(() async {
      s.reconnectCurrent();
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    term.play(const ReadyEvent(1, 'claude'));
    term.play(windowsOf(1, two));
    term.play(const TrafficEvent(1, 0, 1));
    await settle(tester);
    expect(s.currentRecord!.phase, Phase.live);
    expect(s.currentRecord!.frozen, isFalse);
    expect(s.sendBlocked(1), isFalse);
    expect(find.byKey(const Key('offline-bar')), findsNothing);
    expect(tester.widget<TermStage>(find.byType(TermStage)).frozen, isFalse);
    await tester.tap(find.byKey(const Key('composer-open')));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const Key('composer-field')), 'ls');
    await tester.pump();
    expect(tester.widget<RappButton>(find.byKey(const Key('composer-send'))).onPressed, isNotNull);
  });

  testWidgets('a reconnected terminal takes the stage again and is viewed', (tester) async {
    await tester.pumpWidget(wrap(window()));
    await openTerm(tester, two);
    // Not network words: it stays 已断开 and waits for 重连.
    term.play(const DisconnectedEvent(1, 'bad token'));
    await settle(tester);
    expect(find.byType(DisconnectedStage), findsOneWidget);
    expect(find.byType(TermStage), findsNothing);
    term.calls.clear();
    term.paneLists[2] = two;
    await tester.runAsync(() async {
      s.reconnectCurrent();
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    expect(term.calls.where((c) => c.$1 == 'start').single.$2['sid'], 2);
    term.play(windowsOf(2, two));
    await settle(tester);
    expect(find.byType(TermStage), findsOneWidget);
    expect(s.currentRecord!.lastSid, isNull);
    final v = term.calls.where((c) => c.$1 == 'view').last.$2;
    expect((v['sid'], v['window']), (2, 3));
    // The old session's link is closed on the terminal port, never the native one.
    expect(term.calls.where((c) => c.$1 == 'close').single.$2['sid'], 1);
    expect(port.calls.where((c) => c.$2['sid'] == 1 || c.$2['sid'] == 2), isEmpty);
  });

  testWidgets('without a terminal port a terminal does not open', (tester) async {
    final plain = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
    addTearDown(plain.dispose);
    await tester.runAsync(() async {
      plain.openOrSwitch('111', app, 'work');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    expect(t.sent.where((m) => m['cmd'] == 'open'), isEmpty);
    expect(port.calls.where((c) => c.$1 == 'start'), isEmpty);
    expect(plain.current!.reason, '这台主控台还不能看终端会话');
    expect(plain.hint, contains('这台主控台还不能看终端会话'));
  });
  group('more than one terminal', () {
    const key = '111/$app';
    const oldRun = 'this window was opened by an older version and cannot be ended';

    /// The device's list: `work` (and [more]), with [shell]/[fg] when the device is new enough to say them.
    Map<String, dynamic> listOf({bool? shell, String? fg, List<String> launchers = const ['Terminal'],
            List<Map<String, dynamic>> more = const []}) =>
        {
          'event': 'terms',
          'id': '111',
          'terms': [
            {'id': app, 'name': 'work', 'command': 'zsh', 'activity': 1, 'fg': ?fg, 'shell': ?shell},
            ...more,
          ],
          'hosts': [
            {'host': null, 'launchers': launchers},
          ],
        };

    /// The hub answers end_term with [endError] (or term_ended), terms with [list], and open_term with the next
    /// `term:pty:n<k>` once [gate] lets it (none: right away).
    void hubAnswers({String? endError, Map<String, dynamic>? list, List<Completer<void>>? gates,
        Map<String, dynamic> Function()? lists}) {
      final ok = t.onSend;
      var made = 0;
      t.onSend = (m) {
        ok?.call(m);
        switch (m['cmd']) {
          case 'end_term':
            t.emit(endError == null
                ? {'event': 'term_ended', 'id': m['id'], 'term': m['term'], 'req': m['req']}
                : {'event': 'error', 'req': m['req'], 'error': endError});
          case 'terms':
            t.emit({...(lists?.call() ?? list ?? listOf()), 'req': m['req']});
          case 'open_term':
            final n = ++made;
            final reply = {'event': 'term_created', 'id': m['id'], 'term': 'term:pty:n$n', 'req': m['req']};
            final gate = gates == null || gates.length < n ? null : gates[n - 1];
            if (gate == null) {
              t.emit(reply);
            } else {
              gate.future.then((_) => t.emit(reply));
            }
        }
      };
    }

    testWidgets('new_term_from_queues: three presses open three terminals beside it, one after another', (tester) async {
      t.emit(listOf(shell: true));
      await tester.pumpWidget(wrap(window()));
      await openTerm(tester, two);
      final gates = [Completer<void>(), Completer<void>(), Completer<void>()];
      hubAnswers(list: listOf(shell: true), gates: gates);
      List<Map<String, dynamic>> asks() => t.sent.where((m) => m['cmd'] == 'open_term').toList();
      await tester.runAsync(() async {
        for (var i = 0; i < 3; i++) {
          unawaited(s.newTermFrom('111', app));
        }
        await flush();
        await flush();
      });
      // One at a time: the second waits for the first to be made.
      expect(asks(), hasLength(1));
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() async {
          gates[i].complete();
          for (var k = 0; k < 6; k++) {
            await flush();
          }
        });
      }
      expect(asks().map((m) => (m['id'], m['from'], m['app'])),
          [('111', app, 'Terminal'), ('111', app, 'Terminal'), ('111', app, 'Terminal')]);
      await settle(tester);
      expect(s.currentKey, '111/term:pty:n3');
    });

    testWidgets('a new terminal on a device with no terminal window says so and opens nothing', (tester) async {
      t.emit(listOf(shell: true));
      await tester.pumpWidget(wrap(window()));
      await openTerm(tester, two);
      t.emit(listOf(shell: true, launchers: const []));
      await settle(tester);
      await tester.runAsync(() => s.newTermFrom('111', app));
      expect(t.sent.where((m) => m['cmd'] == 'open_term'), isEmpty);
      expect(s.hint, '这台设备没有可用的终端窗口');
      // The queue goes on after a failure.
      t.emit(listOf(shell: true));
      await settle(tester);
      hubAnswers(list: listOf(shell: true));
      await tester.runAsync(() => s.newTermFrom('111', app));
      expect(t.sent.where((m) => m['cmd'] == 'open_term'), hasLength(1));
    });

    testWidgets('end_term_removes_record: the record goes, 已结束 once, the next session is current', (tester) async {
      t.emit(listOf(shell: true));
      await tester.pumpWidget(wrap(window()));
      await openTerm(tester, two);
      hubAnswers(list: listOf(shell: true));
      await tester.runAsync(() => s.endTerm(key));
      await settle(tester);
      expect(t.sent.where((m) => m['cmd'] == 'end_term').single, {'cmd': 'end_term', 'id': '111', 'term': app, 'req': anything});
      expect(s.entryFor(key), isNull);
      expect(s.currentKey, isNull);
      expect(s.hint, '已结束 work');
      expect(term.calls.where((c) => c.$1 == 'close').single.$2['sid'], 1);
      // The view's own 'session ended' comes after: nothing more is said.
      s.hint = '';
      term.play(const DisconnectedEvent(1, 'session ended'));
      await settle(tester);
      expect(s.hint, '');
      expect(s.hintHistory.where((h) => h.text == '已结束 work'), hasLength(1));
      expect(opens(), 1);
    });

    testWidgets('the view saying session ended before the hub answers: the record goes once', (tester) async {
      t.emit(listOf(shell: true));
      await tester.pumpWidget(wrap(window()));
      await openTerm(tester, two);
      final ok = t.onSend;
      Map<String, dynamic>? asked;
      t.onSend = (m) {
        ok?.call(m);
        if (m['cmd'] == 'end_term') asked = m;
        if (m['cmd'] == 'terms') t.emit({...listOf(), 'terms': [], 'req': m['req']});
      };
      final done = s.endTerm(key);
      term.play(const DisconnectedEvent(1, 'session ended'));
      await settle(tester);
      expect(s.entryFor(key), isNull);
      expect(s.hint, '已结束 work');
      s.hint = '';
      t.emit({'event': 'term_ended', 'id': '111', 'term': app, 'req': asked!['req']});
      await tester.runAsync(() => done);
      await settle(tester);
      expect(s.hint, '');
      expect(s.hintHistory.where((h) => h.text == '已结束 work'), hasLength(1));
      expect(term.calls.where((c) => c.$1 == 'close').single.$2['sid'], 1);
    });

    for (final (words, why) in [(oldRun, 'an older holder'), ('unsupported', 'an old holder'), ('unknown op', 'an old device')]) {
      testWidgets('end_term_old_holder_hint: $why says the rApp there is too old; the record stays', (tester) async {
        t.emit(listOf(shell: true));
        await tester.pumpWidget(wrap(window()));
        await openTerm(tester, two);
        hubAnswers(endError: words);
        await tester.runAsync(() => s.endTerm(key));
        await settle(tester);
        expect(s.hint, '这台设备的 rApp 太旧，不能结束终端');
        expect(s.currentKey, key);
        expect(s.currentRecord!.phase, Phase.live);
      });
    }

    testWidgets('any other refusal of an end says the hub words; the record stays', (tester) async {
      t.emit(listOf(shell: true));
      await tester.pumpWidget(wrap(window()));
      await openTerm(tester, two);
      hubAnswers(endError: 'device offline');
      await tester.runAsync(() => s.endTerm(key));
      await settle(tester);
      expect(s.hint, 'device offline');
      expect(s.currentKey, key);
    });

    for (final reason in ['session ended', 'no such text terminal']) {
      testWidgets('session_ended_removes_term_record: $reason takes it off with 已结束 and no retry', (tester) async {
        t.emit(listOf(shell: true));
        await tester.pumpWidget(wrap(window()));
        await openTerm(tester, two);
        // The device's list no longer has it.
        hubAnswers(list: {...listOf(), 'terms': []});
        term.play(DisconnectedEvent(1, reason));
        await settle(tester);
        expect(s.entryFor(key), isNull);
        expect(s.hint, '已结束 work');
        expect(find.byType(DisconnectedStage), findsNothing);
        expect(term.calls.where((c) => c.$1 == 'close').single.$2['sid'], 1);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
        expect(opens(), 1);
      });
    }

    testWidgets('a view answered no such text terminal while the list still has it: 已断开, and it tries again',
        (tester) async {
      t.emit(listOf(shell: true));
      await tester.pumpWidget(wrap(window()));
      await openTerm(tester, two);
      hubAnswers(list: listOf(shell: true));
      term.play(const DisconnectedEvent(1, 'no such text terminal'));
      await settle(tester);
      expect(t.sent.where((m) => m['cmd'] == 'terms'), isNotEmpty);
      expect(s.currentKey, key);
      expect(s.currentRecord!.phase, Phase.disconnected);
      expect(s.currentRecord!.retry, isNotNull);
      expect(s.hintHistory.where((h) => h.text == '已结束 work'), isEmpty);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
      await tester.pump();
      expect(opens(), 2);
    });

    testWidgets('a view answered no such text terminal and no list in time: 已断开, and it tries again', (tester) async {
      t.emit(listOf(shell: true));
      await tester.pumpWidget(wrap(window()));
      await openTerm(tester, two);
      s.termListTimeout = const Duration(milliseconds: 50); // the hub never answers `terms`
      term.play(const DisconnectedEvent(1, 'no such text terminal'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await settle(tester);
      expect(s.currentKey, key);
      expect(s.currentRecord!.phase, Phase.disconnected);
      expect(s.currentRecord!.retry, isNotNull);
    });

    testWidgets('network_drop_still_reconnects: a dropped link stays 已断开 and tries again', (tester) async {
      t.emit(listOf(shell: true));
      await tester.pumpWidget(wrap(window()));
      await openTerm(tester, two);
      term.play(const DisconnectedEvent(1, 'connection closed'));
      await settle(tester);
      expect(s.currentKey, key);
      expect(s.currentRecord!.phase, Phase.disconnected);
      expect(s.currentRecord!.retry, isNotNull);
      expect(s.current!.reason, '网络断了');
    });

    testWidgets('endTermAsk: a shell in front ends without asking; a program asks first; an old device does nothing',
        (tester) async {
      await tester.pumpWidget(wrap(window()));
      await openTerm(tester, two);
      var now = listOf();
      // The record stays, so each case starts from the same one; a fresh `terms` says what the last list said.
      hubAnswers(endError: 'device offline', lists: () => now);
      final asked = <String?>[];
      Future<bool> no(String? fg) async {
        asked.add(fg);
        return false;
      }

      int ends() => t.sent.where((m) => m['cmd'] == 'end_term').length;
      t.emit(now = listOf());
      await settle(tester);
      expect(s.canEndTerm(key), isFalse);
      await tester.runAsync(() => s.endTermAsk(key, confirm: no));
      expect(asked, isEmpty);
      expect(ends(), 0);

      t.emit(now = listOf(shell: true, fg: 'zsh'));
      await settle(tester);
      expect(s.canEndTerm(key), isTrue);
      await tester.runAsync(() => s.endTermAsk(key, confirm: no));
      expect(asked, isEmpty);
      expect(ends(), 1);

      t.emit(now = listOf(shell: false, fg: 'vim'));
      await settle(tester);
      await tester.runAsync(() => s.endTermAsk(key, confirm: no));
      expect(asked, ['vim']);
      expect(ends(), 1);
      await tester.runAsync(() => s.endTermAsk(key, confirm: (fg) async => true));
      expect(ends(), 2);
    });

    testWidgets('endTermAsk asks the device again: a program started since the last list is asked about',
        (tester) async {
      await tester.pumpWidget(wrap(window()));
      await openTerm(tester, two);
      t.emit(listOf(shell: true, fg: 'zsh'));
      await settle(tester);
      // The cached row says the shell is in front; the device now says claude is.
      hubAnswers(endError: 'device offline', list: listOf(shell: false, fg: 'claude'));
      final asked = <String?>[];
      await tester.runAsync(() => s.endTermAsk(key, confirm: (fg) async {
            asked.add(fg);
            return false;
          }));
      expect(t.sent.where((m) => m['cmd'] == 'terms'), isNotEmpty);
      expect(asked, ['claude']);
      expect(t.sent.where((m) => m['cmd'] == 'end_term'), isEmpty);
    });

    testWidgets('endTermAsk with no fresh list goes by the cached row', (tester) async {
      await tester.pumpWidget(wrap(window()));
      await openTerm(tester, two);
      t.emit(listOf(shell: true, fg: 'zsh'));
      await settle(tester);
      s.termListTimeout = const Duration(milliseconds: 50); // `terms` is never answered
      hubAnswers(endError: 'device offline');
      final ok = t.onSend;
      t.onSend = (m) => m['cmd'] == 'terms' ? null : ok?.call(m);
      final asked = <String?>[];
      await tester.runAsync(() => s.endTermAsk(key, confirm: (fg) async {
            asked.add(fg);
            return false;
          }));
      expect(asked, isEmpty);
      expect(t.sent.where((m) => m['cmd'] == 'end_term'), hasLength(1));
    });

    testWidgets('menu_shows_end_term_only_with_shell: 关闭 for a terminal, 结束终端 only on a new device', (tester) async {
      await tester.pumpWidget(wrap(window(width: 500)));
      t.emit(listOf());
      await openTerm(tester, two);
      await tester.tap(find.byKey(const Key('traffic')));
      await tester.pumpAndSettle();
      expect(find.text('关闭'), findsWidgets);
      expect(find.text('结束会话'), findsNothing);
      expect(find.text('结束终端'), findsNothing);
      await tester.tap(find.byKey(const Key('traffic')));
      await tester.pumpAndSettle();

      t.emit(listOf(shell: true, fg: 'zsh'));
      await settle(tester);
      hubAnswers(list: listOf(shell: true));
      await tester.tap(find.byKey(const Key('traffic')));
      await tester.pumpAndSettle();
      expect(find.text('结束终端'), findsOneWidget);
      await tester.tap(find.text('结束终端'));
      await settle(tester);
      // A shell in front: no question, it ends.
      expect(find.byType(AlertDialog), findsNothing);
      expect(t.sent.where((m) => m['cmd'] == 'end_term'), hasLength(1));
      expect(s.entryFor(key), isNull);
    });

    testWidgets('结束终端 with a program in front asks first, and 取消 keeps it', (tester) async {
      await tester.pumpWidget(wrap(window(width: 500)));
      t.emit(listOf(shell: false, fg: 'vim'));
      await openTerm(tester, two);
      hubAnswers(list: listOf(shell: false, fg: 'vim'));
      await tester.tap(find.byKey(const Key('traffic')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('结束终端'));
      await tester.pumpAndSettle();
      expect(find.text('结束终端？'), findsOneWidget);
      expect(find.text('里面还在跑 vim，结束后它也会被关掉。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(t.sent.where((m) => m['cmd'] == 'end_term'), isEmpty);
      expect(s.currentKey, key);
    });

    testWidgets('⌘T in a terminal opens one beside it, and is not typed', (tester) async {
      await tester.pumpWidget(wrap(window()));
      t.emit(listOf(shell: true, fg: 'zsh'));
      await openTerm(tester, two);
      hubAnswers(list: listOf(shell: true));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await settle(tester);
      expect(t.sent.where((m) => m['cmd'] == 'open_term').single['from'], app);
      expect(term.calls.where((c) => c.$1 == 'keys' || c.$1 == 'type'), isEmpty);
      await tester.pump(const Duration(seconds: 1)); // the new terminal's resize wait
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('⌘W in a terminal ends it on a new device, and bubbles on an old one', (tester) async {
      await tester.pumpWidget(wrap(window()));
      t.emit(listOf());
      await openTerm(tester, two);
      hubAnswers(list: listOf(shell: true));
      Future<void> cmdW() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await settle(tester);
      }

      await cmdW();
      expect(t.sent.where((m) => m['cmd'] == 'end_term'), isEmpty);
      t.emit(listOf(shell: true, fg: 'zsh'));
      await settle(tester);
      await cmdW();
      expect(t.sent.where((m) => m['cmd'] == 'end_term'), hasLength(1));
      expect(s.entryFor(key), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a held ⌘T opens one terminal, and a held ⌘W ends once; the repeats are not typed', (tester) async {
      await tester.pumpWidget(wrap(window()));
      t.emit(listOf(shell: true, fg: 'zsh'));
      await openTerm(tester, two);
      hubAnswers(list: listOf(shell: true, fg: 'zsh'), endError: 'device offline'); // the record stays for the repeats
      Future<void> hold(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyDownEvent(key);
        await tester.sendKeyRepeatEvent(key);
        await tester.sendKeyRepeatEvent(key);
        await tester.sendKeyUpEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await settle(tester);
      }

      await hold(LogicalKeyboardKey.keyW);
      expect(t.sent.where((m) => m['cmd'] == 'end_term'), hasLength(1));
      await hold(LogicalKeyboardKey.keyT);
      expect(t.sent.where((m) => m['cmd'] == 'open_term'), hasLength(1));
      expect(term.calls.where((c) => c.$1 == 'keys' || c.$1 == 'type'), isEmpty);
      await tester.pump(const Duration(seconds: 1));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('an end answered no such text terminal is an end: 已结束, not the device words', (tester) async {
      t.emit(listOf(shell: true));
      await tester.pumpWidget(wrap(window()));
      await openTerm(tester, two);
      hubAnswers(endError: 'no such text terminal');
      await tester.runAsync(() => s.endTerm(key));
      await settle(tester);
      expect(s.entryFor(key), isNull);
      expect(s.hint, '已结束 work');
      expect(term.calls.where((c) => c.$1 == 'close').single.$2['sid'], 1);
    });

    testWidgets('a ⌘T the hub never answers does not hold up the next one', (tester) async {
      t.emit(listOf(shell: true));
      await tester.pumpWidget(wrap(window()));
      await openTerm(tester, two);
      s.newTermTimeout = const Duration(milliseconds: 50);
      hubAnswers(list: listOf(shell: true), gates: [Completer<void>()]); // the first is never made
      await tester.runAsync(() async {
        unawaited(s.newTermFrom('111', app));
        await s.newTermFrom('111', app);
      });
      await settle(tester);
      expect(t.sent.where((m) => m['cmd'] == 'open_term'), hasLength(2));
      expect(s.hintHistory.map((h) => h.text), contains('新建终端没有回应，请稍后再试'));
      expect(s.currentKey, '111/term:pty:n2');
      await tester.pump(const Duration(seconds: 1));
    });

    for (final opens in [true, false]) {
      testWidgets('ended while it reconnects: the record stays gone with one hint (the open ${opens ? 'answers' : 'fails'})',
          (tester) async {
        t.emit(listOf(shell: true));
        await tester.pumpWidget(wrap(window()));
        await openTerm(tester, two);
        term.play(const DisconnectedEvent(1, 'bad token'));
        await settle(tester);
        hubAnswers(list: listOf(shell: true));
        final answer = t.onSend;
        Map<String, dynamic>? held;
        t.onSend = (m) => m['cmd'] == 'open' ? held = m : answer?.call(m);
        await tester.runAsync(() async {
          s.reconnectCurrent();
          await flush();
        });
        expect(held, isNotNull);
        expect(s.currentRecord!.phase, Phase.connecting);
        await tester.runAsync(() => s.endTerm(key));
        await settle(tester);
        expect(s.entryFor(key), isNull);
        t.emit(opens
            ? {'event': 'opened', 'sid': 2, 'id': '111', 'app': app, 'path': 'lan', 'port': 5001, 'token': 'tk',
                'req': held!['req']}
            : {'event': 'error', 'req': held!['req'], 'error': 'cannot reach the host'});
        await settle(tester);
        expect(s.entryFor(key), isNull);
        expect(s.hintHistory.where((h) => h.text == '已结束 work'), hasLength(1));
        expect(s.hint, '已结束 work');
        expect(s.remote.containsKey(2), isFalse);
        expect(term.calls.where((c) => c.$1 == 'start' && c.$2['sid'] == 2), isEmpty);
        if (opens) expect(t.sent.where((m) => m['cmd'] == 'close' && m['sid'] == 2), hasLength(1));
      });
    }

    testWidgets('Ctrl+Shift+T opens one beside it off the mac', (tester) async {
      await tester.pumpWidget(wrap(window()));
      t.emit(listOf(shell: true, fg: 'zsh'));
      await openTerm(tester, two);
      hubAnswers(list: listOf(shell: true));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(t.sent.where((m) => m['cmd'] == 'open_term').single['from'], app);
      await tester.pump(const Duration(seconds: 1));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });

  group('with the real terminal port', () {
    late ServerSocket worker;
    final conns = <Socket>[];

    int opens() => t.sent.where((m) => m['cmd'] == 'open').length;

    Future<void> until(bool Function() ok, {Duration within = const Duration(seconds: 3)}) async {
      final end = DateTime.now().add(within);
      while (!ok() && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(ok(), isTrue, reason: 'timed out');
    }

    /// A worker that shows one pane, then does [then] to the link; the state opens a terminal on it.
    Future<void> openOn(void Function(Socket c) then) async {
      conns.clear();
      worker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        for (final c in conns) {
          c.destroy();
        }
        await worker.close();
      });
      worker.listen((c) {
        conns.add(c);
        c.listen((_) {}, onError: (_) {});
        c.write('${jsonEncode({'t': 'panes', 'panes': [
              {'id': '%3', 'win': '@1', 'window': 'w', 'title': 't', 'command': 'claude',
               'cols': 80, 'rows': 24, 'dead': false, 'active': true},
            ]})}\n');
        if (conns.length == 1) then(c);
      });
      t.onSend = (m) {
        if (m['cmd'] == 'open') {
          t.emit({
            'event': 'opened', 'sid': nextSid++, 'id': m['id'], 'app': m['app'], 'path': 'lan',
            'port': worker.port, 'token': 'tk', 'req': m['req'],
          });
        }
      };
      final real = TermSessionPort();
      s.dispose();
      s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, termPort: real);
      addTearDown(real.dispose);
      s.openOrSwitch('111', app, 'work');
    }

    test('a terminal whose link drops reconnects by itself like an app session', () async {
      await openOn((c) => Future<void>.delayed(const Duration(milliseconds: 50), c.destroy));
      await until(() => s.currentRecord?.phase == Phase.disconnected);
      expect(s.currentRecord!.retry, isNotNull);
      expect(s.current!.reason, '网络断了');
      await until(() => opens() == 2);
      expect(t.sent.where((m) => m['cmd'] == 'open').last['reconnect'], true);
      await until(() => s.currentRecord?.phase == Phase.live && s.currentRecord?.sid == 2);
    });

    test('a terminal session the device ended leaves the list with 已结束 and does not reconnect', () async {
      await openOn((c) => c.write('${jsonEncode({'t': 'error', 'error': 'session ended'})}\n'));
      await until(() => s.entryFor('111/$app') == null);
      expect(s.hint, '已结束 work');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(opens(), 1);
    });
  });
}
