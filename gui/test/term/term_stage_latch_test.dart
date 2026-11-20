// The terminal stage reads the key bar's sticky modifiers (iOS input toggle, Task 2).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/modifier_latch.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/term/term_stage.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/top_bar.dart';

import '../fakes.dart';
import '../ui/helpers.dart';
import 'term_main_test.dart' show tp, windowsOf;

const app = 'term:pty:work';

const left = ['Ctrl', 'Esc', 'Ctrl-C', 'Tab'];
const right = ['Up', 'Down', 'Enter'];

void main() {
  late FakeTransport t;
  late HubClient hub;
  late Directory tmp;
  late FakeSessionPort port;
  late FakeTermSessionPort term;
  late MainState s;
  var nextSid = 1;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('term_stage_latch_test');
    // A device id: prefs are written to devices/<id>/gui.json.
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"123456789"}');
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

  Widget window(double width) => SizedBox(
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

  Future<void> openTerm(WidgetTester tester, {double width = 1200}) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(window(width), disableAnimations: true));
    final panes = [tp(3, 'claude', title: 'build-box', active: true), tp(4, '', title: 'sh')];
    term.paneLists[1] = panes;
    await tester.runAsync(() async {
      s.openOrSwitch('111', app, 'work');
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    term.play(const ReadyEvent(1, 'work'));
    term.play(windowsOf(1, panes));
    term.play(const TrafficEvent(1, 0, 1));
    await settle(tester);
    expect(find.byType(TermStage), findsOneWidget);
  }

  List<Map<String, Object?>> callsOf(String m) => term.calls.where((c) => c.$1 == m).map((c) => c.$2).toList();
  List<Object?> keys() => [for (final c in callsOf('keys')) c['keys']];


  testWidgets('term_stage: hardware r with keyLatch ctrl sends Ctrl-R', (tester) async {
    await openTerm(tester);
    final rs = s.currentRemote!;
    rs.keyLatch.tap(latchCtrl);
    term.calls.clear();
    final grid = find.byKey(const Key('term-grid'));
    Focus.of(tester.element(grid)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(keys(), [
      ['Ctrl-R'],
    ]);
    expect(rs.keyLatch.flags, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    expect(term.calls.where((c) => c.$1 == 'type').length, 1, reason: 'the latch was used up: the next r is plain');
  });

  testWidgets('term_stage: an arrow with keyLatch alt goes as Alt-Left', (tester) async {
    await openTerm(tester);
    final rs = s.currentRemote!;
    rs.keyLatch.tap(latchOpt);
    term.calls.clear();
    Focus.of(tester.element(find.byKey(const Key('term-grid')))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(keys(), [
      ['Alt-Left'],
    ]);
    expect(rs.keyLatch.flags, 0);
  });
}
