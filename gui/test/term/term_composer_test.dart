// The writing panel on a terminal session (G2 task 6): what it sends goes to the pane as one paste.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/composer_panel.dart' show pictureLift;
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/term/term_session_port.dart';
import 'package:rapp/term/term_stage.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/top_bar.dart';

import '../fakes.dart';
import '../ui/helpers.dart';
import 'term_main_test.dart' show tp, windowsOf;

const app = 'term:tmux:work';

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
    tmp = Directory.systemTemp.createTempSync('term_composer_test');
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

  // The window's Ctrl+Enter as main_window.dart binds it (on every platform).
  Widget window({double width = 1200}) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true, includeRepeats: false): s.composerKey,
        },
        child: Focus(
          autofocus: true,
          child: SizedBox(
            width: width,
            height: 700,
            child: Column(children: [
              TopBar(state: s, fullscreen: false, onToggleFullscreen: () {}),
              Expanded(child: Stage(state: s)),
            ]),
          ),
        ),
      );

  void big(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    await tester.pump();
    await tester.pump();
  }

  Future<void> openTerm(WidgetTester tester, {bool disableAnimations = false}) async {
    big(tester);
    await tester.pumpWidget(wrap(window(), disableAnimations: disableAnimations));
    final panes = [tp(3, 'claude', title: 'build-box', active: true), tp(4, '', title: 'sh')];
    // The session's name differs from the pane's command here, to tell the two apart.
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

  final fieldFinder = find.byKey(const Key('composer-field'));
  TextField field(WidgetTester tester) => tester.widget<TextField>(fieldFinder);
  String text(WidgetTester tester) => field(tester).controller!.text;
  bool fieldFocused(WidgetTester tester) => field(tester).focusNode!.hasFocus;
  bool stageFocused(WidgetTester tester) => Focus.of(tester.element(find.byKey(const Key('term-grid')))).hasFocus;

  void clipboard(WidgetTester tester, String text) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': text};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  Future<void> chord(WidgetTester tester, List<LogicalKeyboardKey> mods, LogicalKeyboardKey key) async {
    for (final m in mods) {
      await tester.sendKeyDownEvent(m);
    }
    await tester.sendKeyEvent(key);
    for (final m in mods.reversed) {
      await tester.sendKeyUpEvent(m);
    }
    await tester.pump();
  }

  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('composer-open')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('composer-panel')), findsOneWidget);
  }

  Future<void> send(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('composer-send')));
    await settle(tester);
  }

  testWidgets('the terminal stage has 「输入」; the panel opens with 写给 <command>, the caret in it', (tester) async {
    await openTerm(tester);
    expect(find.byKey(const Key('composer-open')), findsOneWidget);
    await tester.tap(find.byKey(const Key('term-grid')));
    await tester.pump();
    expect(stageFocused(tester), isTrue);
    await openPanel(tester);
    await tester.pump();
    expect(find.text('写给 claude'), findsOneWidget);
    // The panel keeps the caret: the stage does not take it back.
    expect(fieldFocused(tester), isTrue);
    expect(stageFocused(tester), isFalse);
    // A pane with no command: the session's name.
    s.selectWindow(4);
    await settle(tester);
    expect(find.text('写给 work'), findsOneWidget);
  });

  testWidgets('a send goes out as one paste without Return; success empties the box', (tester) async {
    await openTerm(tester);
    await openPanel(tester);
    term.calls.clear();
    final gate = term.pasteWait = Completer<String?>();
    await tester.enterText(fieldFinder, '你好\n世界');
    await send(tester);
    expect(callsOf('paste').single, {'sid': 1, 'data': '你好\n世界', 'enter': false});
    // Sending is said before the paste goes out; done waits for the answer.
    expect([for (final c in term.calls) c.$1], ['composer', 'paste']);
    expect(callsOf('composer').single['sending'], isTrue);
    expect(find.text('发送中'), findsOneWidget);
    gate.complete(null);
    await settle(tester);
    expect(callsOf('composer').last, {'sid': 1, 'sending': false, 'sent': 1, 'failure': null});
    expect(text(tester), isEmpty);
    expect(find.text('发送中'), findsNothing);
    expect(keys(), isEmpty, reason: 'no Return without afterSend');
  });

  testWidgets('afterSend pressReturn sends Enter after the paste is in', (tester) async {
    await openTerm(tester);
    s.currentRemote!.setProfile(const ResolvedProfile(afterSend: AfterSend.pressReturn));
    await openPanel(tester);
    term.calls.clear();
    await tester.enterText(fieldFinder, 'ls');
    await send(tester);
    expect([for (final c in term.calls) c.$1], ['composer', 'paste', 'composer', 'keys']);
    expect(keys(), [
      ['Enter'],
    ]);
  });

  testWidgets('a failed paste keeps the text and says why', (tester) async {
    await openTerm(tester);
    await openPanel(tester);
    term.pasteReply = pasteTooLong;
    await tester.enterText(fieldFinder, 'abc');
    await send(tester);
    expect(callsOf('composer').last['failure'], pasteTooLong);
    expect(find.text(pasteTooLong), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    final c = s.currentRemote!.composer;
    expect(c.failed.single.text, 'abc');
    await tester.tap(find.text('放回输入框'));
    await tester.pump();
    expect(text(tester), 'abc');
  });

  testWidgets('an empty Enter in the panel is an Enter for the pane', (tester) async {
    await openTerm(tester);
    await openPanel(tester);
    term.calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(keys(), [
      ['Enter'],
    ]);
    expect(callsOf('paste'), isEmpty);
  });

  testWidgets('「＋」 has the 15 terminal keys, 附件… greyed, no 在远端复制', (tester) async {
    await openTerm(tester);
    await openPanel(tester);
    await tester.tap(find.byKey(const Key('composer-plus')));
    await tester.pump();
    expect(find.byKey(const Key('composer-plus-menu')), findsOneWidget);
    const labels = ['Esc', 'Tab', '⇧Tab', '删除', '回车', '←', '↓', '↑', '→', '⌃C', '⌃D', '⌃L', '⌃R', 'PgUp', 'PgDn'];
    for (final l in labels) {
      expect(find.descendant(of: find.byKey(const Key('composer-plus-menu')), matching: find.text(l)), findsOneWidget,
          reason: l);
    }
    expect(find.byKey(const ValueKey('sticky-⌘')), findsNothing);
    expect(find.byKey(const ValueKey('sticky-⌥')), findsNothing);
    expect(find.text('在远端复制'), findsNothing);
    expect(find.text('终端会话不支持'), findsOneWidget);
    expect(find.text('输入历史'), findsOneWidget);
    term.calls.clear();
    await tester.tap(find.text('附件…'));
    await tester.pump();
    expect(term.calls, isEmpty);
    expect(find.byKey(const Key('composer-plus-menu')), findsOneWidget);
    const names = ['Esc', 'Tab', 'Shift-Tab', 'Backspace', 'Enter', 'Left', 'Down', 'Up', 'Right', 'Ctrl-C', 'Ctrl-D',
        'Ctrl-L', 'Ctrl-R', 'PageUp', 'PageDown'];
    for (final l in labels) {
      await tester.tap(find.descendant(of: find.byKey(const Key('composer-plus-menu')), matching: find.text(l)));
      await tester.pump();
    }
    expect(keys(), [
      for (final n in names) [n],
    ]);
  });

  testWidgets('W14: a short paste goes into the text; 12 lines become a block, spliced in at send', (tester) async {
    await openTerm(tester);
    await openPanel(tester);
    // ⌘V is the panel's own paste on macOS (elsewhere Ctrl+V is the text field's).
    const mod = LogicalKeyboardKey.metaLeft;
    clipboard(tester, '一\n二');
    await chord(tester, [mod], LogicalKeyboardKey.keyV);
    await settle(tester);
    expect(text(tester), '一\n二');
    await tester.enterText(fieldFinder, '');
    final twelve = List.generate(12, (i) => 'line $i').join('\n');
    clipboard(tester, twelve);
    await chord(tester, [mod], LogicalKeyboardKey.keyV);
    await settle(tester);
    expect(text(tester), isEmpty);
    expect(find.text('[贴入文字 #1 +12 行]'), findsOneWidget);
    await tester.enterText(fieldFinder, '看看这段');
    term.calls.clear();
    await send(tester);
    expect(callsOf('paste').single['data'], '$twelve看看这段');
    expect(find.text('[贴入文字 #1 +12 行]'), findsNothing);
    // The sent block is let go: the port holds it no more.
    term.calls.clear();
    term.composerSend(1, [
      {'block': 1},
    ]);
    expect(callsOf('paste'), isEmpty);
    expect(callsOf('composer').last['failure'], pasteFailed);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a multi-line paste on the stage opens the panel, which pastes it as a block (K4, W14)', (tester) async {
    await openTerm(tester);
    await tester.tap(find.byKey(const Key('term-grid')));
    await tester.pump();
    expect(stageFocused(tester), isTrue);
    final twelve = List.generate(12, (i) => 'line $i').join('\n');
    clipboard(tester, twelve);
    term.calls.clear();
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await chord(tester, [LogicalKeyboardKey.metaLeft], LogicalKeyboardKey.keyV);
    } else {
      await chord(tester, [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft], LogicalKeyboardKey.keyV);
    }
    await settle(tester);
    await settle(tester);
    expect(find.byKey(const Key('composer-panel')), findsOneWidget);
    expect(find.text('[贴入文字 #1 +12 行]'), findsOneWidget);
    expect(fieldFocused(tester), isTrue);
    expect(callsOf('paste'), isEmpty, reason: 'nothing straight to the pane');
  });

  testWidgets('Ctrl+Enter on the focused stage opens the panel and is not sent to the terminal', (tester) async {
    await openTerm(tester);
    await tester.tap(find.byKey(const Key('term-grid')));
    await tester.pump();
    expect(stageFocused(tester), isTrue);
    term.calls.clear();
    await chord(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byKey(const Key('composer-panel')), findsOneWidget);
    expect(fieldFocused(tester), isTrue);
    expect(stageFocused(tester), isFalse);
    expect(callsOf('keys'), isEmpty);
    expect(callsOf('type'), isEmpty);
    // Again, from the editor: the keys go back to the stage, the panel stays.
    await chord(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('composer-panel')), findsOneWidget);
    expect(stageFocused(tester), isTrue);
  });

  for (final off in [false, true]) {
    testWidgets('opening and closing the panel lifts the picture by $pictureLift, never resizes it '
        '(animations ${off ? 'off' : 'on'}; Review Focus 5)', (tester) async {
      await openTerm(tester, disableAnimations: off);
      final size = tester.getSize(find.byType(TermStage));
      final top = tester.getTopLeft(find.byType(TermStage)).dy;
      term.calls.clear();
      await openPanel(tester);
      if (!off) {
        await tester.pump(const Duration(milliseconds: 75));
        final mid = tester.getTopLeft(find.byType(TermStage)).dy;
        expect(mid, lessThan(top));
        expect(mid, greaterThan(top - pictureLift));
      }
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getSize(find.byType(TermStage)), size);
      expect(tester.getTopLeft(find.byType(TermStage)).dy, top - pictureLift);
      expect(fieldFocused(tester), isTrue);
      s.currentRemote!.composer.collapse();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getTopLeft(find.byType(TermStage)).dy, top);
      expect(tester.getSize(find.byType(TermStage)), size);
      expect(callsOf('view'), isEmpty);
    });
  }

  group('the port on its own', () {
    late TermSessionPort p;
    final events = <SessionEvent>[];

    setUp(() {
      p = TermSessionPort();
      events.clear();
      p.events.listen(events.add);
    });
    tearDown(() => p.dispose());

    testWidgets('composerPaste: W14 by characters and lines; a block is kept until dropped', (tester) async {
      Future<PasteResult> pasteOf(String v) async {
        clipboard(tester, v);
        return p.composerPaste(1);
      }

      expect((await pasteOf('a' * 799)).text, 'a' * 799);
      expect((await pasteOf('字' * 799)).text, '字' * 799, reason: 'characters, not bytes');
      final r800 = await pasteOf('a' * 800);
      expect(r800.text, isNull);
      expect(r800.blocks.single.label, '[贴入文字 #1 +1 行]');
      expect(r800.blocks.single.kind, 'text');
      final nine = List.filled(9, 'x').join('\n');
      expect((await pasteOf(nine)).text, nine);
      final ten = List.filled(10, 'x').join('\n');
      final r10 = await pasteOf(ten);
      expect(r10.text, isNull);
      expect(r10.blocks.single.n, 2);
      expect(r10.blocks.single.label, '[贴入文字 #2 +10 行]');
      expect(r10.blocks.single.text, ten);
      // Held: it goes to the paste (no link here); dropped: it is not there to send.
      events.clear();
      await tester.runAsync(() async {
        p.composerSend(1, [
          {'block': 2},
        ]);
        await flush();
        await flush();
      });
      expect(events.whereType<ComposerStateEvent>().last.done!.failure, linkGone);
      p.composerDropBlock(1, 2);
      events.clear();
      await tester.runAsync(() async {
        p.composerSend(1, [
          {'block': 2},
        ]);
        await flush();
        await flush();
      });
      expect(events.whereType<ComposerStateEvent>().last.done!.failure, pasteFailed);
      final empty = await pasteOf('');
      expect((empty.text, empty.blocks.length, empty.status), (null, 0, null));
    });

    testWidgets('composerAttach is not for terminals', (tester) async {
      final r = await p.composerAttach(1);
      expect((r.text, r.blocks.length, r.status), (null, 0, '终端会话不支持'));
    });

    testWidgets('composerSend over 1 MiB: sending, then done with nothing sent and why', (tester) async {
      await tester.runAsync(() async {
        p.composerSend(1, [
          {'text': 'a' * (maxPaste + 1)},
        ]);
        await flush();
        await flush();
      });
      final c = events.whereType<ComposerStateEvent>().toList();
      expect(c.first.sending, isTrue);
      expect((c.last.sending, c.last.done?.sent, c.last.done?.failure), (false, 0, pasteTooLong));
    });

    testWidgets('composerSend: a block no longer held is not sent', (tester) async {
      await tester.runAsync(() async {
        p.composerSend(1, [
          {'block': 9},
        ]);
        await flush();
        await flush();
      });
      final d = events.whereType<ComposerStateEvent>().last.done!;
      expect(d.sent, 0);
      expect(d.failure, isNotNull);
    });
  });
}
