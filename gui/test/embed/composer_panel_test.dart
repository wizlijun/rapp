import 'dart:io';

import 'package:rapp/paths.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/picture.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/history/history_list.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';
import 'package:rapp/ui/tokens.dart';

import '../fakes.dart';
import '../ui/helpers.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late FakeSessionPort port;
  late MainState es;
  late Directory tmp;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('composer_panel_test');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await flush();
    port = FakeSessionPort();
    es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
  });

  tearDown(() {
    es.dispose();
    tmp.deleteSync(recursive: true);
  });

  List<Map<String, Object?>> callsOf(String method) =>
      port.calls.where((c) => c.$1 == method).map((c) => c.$2).toList();

  final fieldFinder = find.byKey(const Key('composer-field'));
  TextField field(WidgetTester tester) => tester.widget<TextField>(fieldFinder);
  String text(WidgetTester tester) => field(tester).controller!.text;
  bool fieldFocused(WidgetTester tester) => field(tester).focusNode!.hasFocus;

  test('panelWidth is 720, or the stage less 16 below 736', () {
    expect(panelWidth(1200), 720);
    expect(panelWidth(736), 720);
    expect(panelWidth(700), 684);
  });

  group('panel', () {
    late RemoteSession rs;

    setUp(() {
      rs = RemoteSession(1, 'Safari',
          onDropBlock: (n) => port.composerDropBlock(1, n),
          onReturn: () => port.key(1, 36, 0),
          onSelectInput: (id) => port.selectInput(1, id));
      rs.composer.open = true;
    });
    tearDown(() => rs.dispose());

    Widget panel() =>
        SizedBox(width: 720, child: ComposerPanel(state: es, session: rs, port: port, maxHeight: 300));

    // A 1000×700 stage with the composer layer on it.
    Widget layer({RemoteSession? s}) => wrap(SizedBox(
        key: const Key('host'),
        width: 1000,
        height: 700,
        child: Stack(children: composerLayer(state: es, session: s ?? rs, port: port))));

    void big(WidgetTester tester) {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Rect rect(WidgetTester tester, String key) => tester.getRect(find.byKey(Key(key)));

    testWidgets('open: one line, 720 wide, centred, 8 above the stage bottom', (tester) async {
      big(tester);
      await tester.pumpWidget(layer());
      await tester.pump();
      final host = rect(tester, 'host');
      final p = rect(tester, 'composer-panel');
      expect(p.size, const Size(720, 48 + 2)); // one 48 line inside a 1 px border
      expect(p.center.dx - host.left, 500);
      expect(p.bottom - host.top, 692);
      // W2: 15 on 22, no MATRIX glow in the editor.
      final style = field(tester).style!;
      expect(style.fontSize, 15);
      expect(style.height, 22 / 15);
      expect(style.shadows, isEmpty);
    });

    testWidgets('long text grows upward to half the stage, bottom and width fixed', (tester) async {
      big(tester);
      await tester.pumpWidget(layer());
      await tester.pump();
      final before = rect(tester, 'composer-panel');
      rs.composer.setDraft(List.generate(40, (i) => 'line $i').join('\n'));
      await tester.pump(); // W16: one frame, no animation
      final after = rect(tester, 'composer-panel');
      expect(after.height, greaterThan(before.height));
      expect(after.height, lessThanOrEqualTo(350));
      expect(after.bottom, before.bottom);
      expect(after.left, before.left);
      expect(after.width, before.width);
    });

    testWidgets('Enter sends and the box stays, one line, caret inside (W7)', (tester) async {
      big(tester);
      await tester.pumpWidget(layer());
      await tester.pump();
      await tester.enterText(fieldFinder, 'a');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      final sent = callsOf('composer_send');
      expect(sent.single['sid'], 1);
      expect(sent.single['pieces'], [
        {'text': 'a'},
      ]);
      expect(text(tester), isEmpty);
      expect(rect(tester, 'composer-box').height, 50);
      expect(fieldFocused(tester), isTrue);
      expect(find.text('发送中'), findsOneWidget);
      rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
      await tester.pump();
      expect(find.text('发送中'), findsNothing);
      expect(find.byKey(const Key('composer-panel')), findsOneWidget);
    });

    testWidgets('the send button sends, and waits while a send runs', (tester) async {
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      expect(find.bySemanticsLabel('发送'), findsOneWidget);
      await tester.enterText(fieldFinder, 'x');
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pump();
      expect(callsOf('composer_send').single['pieces'], [
        {'text': 'x'},
      ]);
      await tester.enterText(fieldFinder, 'y');
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pump();
      expect(callsOf('composer_send').length, 1);
      expect(text(tester), 'y');
    });

    testWidgets('a send switches A to English first; an empty Enter presses Return', (tester) async {
      rs.apply(const InputSourceEvent(1, 'im', '拼音', false));
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      expect(fieldFocused(tester), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(callsOf('key'), [
        {'sid': 1, 'keyCode': 36, 'modifiers': 0},
      ]);
      expect(callsOf('composer_send'), isEmpty);
      expect(find.text('已给远端发回车'), findsNothing); // W11

      port.calls.clear();
      await tester.enterText(fieldFinder, 'hi');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect([for (final c in port.calls) c.$1].where((m) => m == 'select_input' || m == 'composer_send'),
          ['select_input', 'composer_send']);
      rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
      await tester.pump();
      expect(text(tester), isEmpty);
      expect(find.textContaining('已发送'), findsNothing); // W11
    });

    testWidgets('an empty Enter right after a send does nothing (W15)', (tester) async {
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      await tester.enterText(fieldFinder, 'a');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
      await tester.pump();
      port.calls.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(callsOf('key'), isEmpty);
      expect(callsOf('composer_send'), isEmpty);
    });

    testWidgets('a failed send offers retry and put back', (tester) async {
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      await tester.enterText(fieldFinder, 'hello');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      rs.apply(const ComposerStateEvent(1, done: ComposerDone(0, 'A 上贴不进去')));
      await tester.pump();
      expect(find.text('A 上贴不进去'), findsOneWidget);
      expect(text(tester), isEmpty);
      await tester.tap(find.text('放回输入框'));
      await tester.pump();
      expect(text(tester), 'hello');
      expect(find.text('A 上贴不进去'), findsNothing);

      // The block went, the text did not: 重试 sends what is left.
      rs.composer.apply(const PasteResult(blocks: [BlockChip(1, '[图片 #1 10×20]')]));
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pump();
      expect(callsOf('composer_send').last['pieces'], [
        {'block': 1},
        {'text': 'hello'},
      ]);
      rs.apply(const ComposerStateEvent(1, done: ComposerDone(1, 'boom')));
      await tester.pump();
      expect(find.text('boom'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      final sent = callsOf('composer_send');
      expect(sent.length, 3);
      expect(sent.last['pieces'], [
        {'text': 'hello'},
      ]);
      expect(find.text('boom'), findsNothing);
      expect(find.text('发送中'), findsOneWidget);
    });

    testWidgets('重试 is off while a send waits for the input method to commit (I1)', (tester) async {
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      await tester.enterText(fieldFinder, 'x');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      rs.apply(const ComposerStateEvent(1, done: ComposerDone(0, 'boom')));
      await tester.pump();
      RappButton retry() => tester.widget<RappButton>(find.widgetWithText(RappButton, '重试'));
      expect(retry().onPressed, isNotNull);
      field(tester).controller!.value = const TextEditingValue(
          text: 'ni', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2));
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pump();
      expect(rs.composer.taking, isTrue);
      expect(retry().onPressed, isNull);
      field(tester).controller!.value =
          const TextEditingValue(text: '你', selection: TextSelection.collapsed(offset: 1));
      await tester.pump();
      final sent = callsOf('composer_send');
      expect(sent.length, 2);
      expect(sent.last['pieces'], [
        {'text': '你'},
      ]);
      expect(rs.composer.failed.single.text, 'x');
      expect(retry().onPressed, isNull); // sending
    });

    testWidgets('tapping a block removes it; blocks sit above the text inside the box', (tester) async {
      rs.composer.apply(const PasteResult(blocks: [BlockChip(1, '[图片 #1 10×20]'), BlockChip(2, '[文件 a 1 B]')]));
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      final box = rect(tester, 'composer-box');
      final chip = tester.getRect(find.text('[图片 #1 10×20]'));
      final f = tester.getRect(fieldFinder);
      expect(box.contains(chip.topLeft) && box.contains(chip.bottomRight), isTrue);
      expect(chip.bottom, lessThanOrEqualTo(f.top));
      await tester.tap(find.text('[图片 #1 10×20]'));
      await tester.pump();
      expect(find.text('[图片 #1 10×20]'), findsNothing);
      expect(find.text('[文件 a 1 B]'), findsOneWidget);
      expect(callsOf('composer_drop_block'), [
        equals({'sid': 1, 'block': 1}),
      ]);
    });

    testWidgets('the hint is 写给 <app>', (tester) async {
      await tester.pumpWidget(wrap(panel()));
      expect(find.text('写给 Safari'), findsOneWidget);
    });

    testWidgets('send and plus stay at the bottom right when tall (W13)', (tester) async {
      big(tester);
      rs.composer.setDraft(List.generate(10, (i) => 'line $i').join('\n'));
      await tester.pumpWidget(layer());
      await tester.pump();
      final box = rect(tester, 'composer-box');
      final send = rect(tester, 'composer-send');
      final plus = rect(tester, 'composer-plus');
      expect(box.height, greaterThan(100));
      expect(send.size, const Size(48, 48));
      expect(plus.size, const Size(48, 48));
      expect(send.bottom, box.bottom - 1); // inside the 1 px border
      expect(plus.bottom, box.bottom - 1);
      expect(send.right, box.right - 1);
      expect(plus.right, lessThanOrEqualTo(send.left));
    });

    testWidgets('⌘V pastes what the runner answers at the cursor', (tester) async {
      port.pasteReply = {'text': 'hello'};
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      await tester.pump();
      expect(callsOf('composer_paste'), [
        equals({'sid': 1}),
      ]);
      expect(text(tester), 'hello');
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a paste asked for before the panel is shown runs once it is, once (K4)', (tester) async {
      port.pasteReply = {'text': 'a\nb'};
      rs.composer.requestPaste();
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      await tester.pump();
      expect(callsOf('composer_paste'), [
        equals({'sid': 1}),
      ]);
      expect(text(tester), 'a\nb');
      expect(fieldFocused(tester), isTrue);
      await tester.pump();
      expect(callsOf('composer_paste'), hasLength(1));
    });

    testWidgets('a paste asked for while the panel is shown runs at once', (tester) async {
      port.pasteReply = {'text': 'x'};
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      expect(callsOf('composer_paste'), isEmpty);
      rs.composer.requestPaste();
      await tester.pump();
      await tester.pump();
      expect(callsOf('composer_paste'), hasLength(1));
      expect(text(tester), 'x');
    });

    testWidgets('focusing the field takes focus from the picture', (tester) async {
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({
              'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              'port': 5001, 'token': 'tk', 'req': m['req'],
            });
          }
        };
        es.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pumpWidget(wrap(panel()));
      await tester.pump();
      es.focusPicture(1);
      await tester.tap(fieldFinder);
      await tester.pump();
      expect(es.pictureFocused, isNull);
      expect(port.calls.last.$1, 'picture_focus');
      expect(port.calls.last.$2, equals({'sid': null}));
    });

    testWidgets('no 「输入」 button and no panel while composerAllowed is false; both come back', (tester) async {
      RemoteWindow rw(int id, WindowKind k) => RemoteWindow(
          id: id,
          parent: 0,
          kind: k,
          title: 'w$id',
          rect: const Rect.fromLTWH(0, 0, 100, 100),
          titleBar: 28,
          resizable: true,
          focused: false,
          texture: id,
          visible: const Rect.fromLTWH(0, 0, 1, 1));
      rs.setProfile(const ResolvedProfile(
          name: 'X', windows: [WindowRule(kind: WindowKind.dialog, action: RuleAction.noComposer)]));
      rs.apply(WindowsEvent(1, [rw(1, WindowKind.normal)]));
      rs.apply(WindowsEvent(1, [rw(1, WindowKind.normal), rw(2, WindowKind.dialog)]));
      rs.composer.setDraft('草稿');
      await tester.pumpWidget(wrap(SizedBox(
          width: 900, height: 400, child: Stack(children: composerLayer(state: es, session: rs, port: port)))));
      expect(find.byKey(const Key('composer-panel')), findsNothing);
      expect(find.byKey(const Key('composer-open')), findsNothing);
      rs.selectWindow(1);
      await tester.pump();
      expect(find.byKey(const Key('composer-panel')), findsOneWidget);
      expect(text(tester), '草稿');
    });

    testWidgets('the upload strip and cancel stay while composerAllowed is false; only 输入 goes', (tester) async {
      rs.setProfile(const ResolvedProfile(name: 'X', composer: false));
      rs.apply(const TransferStatusEvent(1, '上传 1/2 · a.txt'));
      await tester.pumpWidget(wrap(SizedBox(
          width: 900, height: 400, child: Stack(children: composerLayer(state: es, session: rs, port: port)))));
      expect(find.byKey(const Key('composer-open')), findsNothing);
      expect(find.text('上传 1/2 · a.txt'), findsOneWidget);
      await tester.tap(find.text('取消'));
      expect(callsOf('cancel_transfer').single, equals({'sid': 1}));
    });

    // What a secondary button over the picture fills with (AVATAR's raise is see-through).
    double fillAlpha(WidgetTester tester, Finder button) => tester
        .widget<OutlinedButton>(find.descendant(of: button, matching: find.byType(OutlinedButton)))
        .style!
        .backgroundColor!
        .resolve(<WidgetState>{})!
        .a;

    testWidgets('输入 and 取消 over the picture are opaque in AVATAR', (tester) async {
      rs.composer.open = false;
      rs.apply(const TransferStatusEvent(1, '上传 1/2 · a.txt'));
      await tester.pumpWidget(wrap(
          SizedBox(width: 900, height: 400, child: Stack(children: composerLayer(state: es, session: rs, port: port))),
          theme: RappTheme.avatar));
      expect(fillAlpha(tester, find.byKey(const Key('composer-open'))), 1.0);
      expect(fillAlpha(tester, find.widgetWithText(RappButton, '取消')), 1.0);
    });

    testWidgets('the hint line\'s 取消 is opaque in AVATAR', (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      rs.apply(const TransferStatusEvent(1, '上传 1/2 · a.txt'));
      await tester.pumpWidget(wrap(
          SizedBox(width: 900, height: 600, child: Stack(children: composerLayer(state: es, session: rs, port: port))),
          theme: RappTheme.avatar));
      await tester.pump();
      final hint = find.byKey(const Key('composer-hint'));
      expect(fillAlpha(tester, find.descendant(of: hint, matching: find.widgetWithText(RappButton, '取消'))), 1.0);
    });

    group('plus menu and hint line', () {
      final menu = find.byKey(const Key('composer-plus-menu'));
      final hint = find.byKey(const Key('composer-hint'));

      Future<void> openMenu(WidgetTester tester) async {
        await tester.tap(find.byKey(const Key('composer-plus')));
        await tester.pump();
      }

      testWidgets('plus opens a menu above it: 附件…, 在远端复制, the keys, 收起', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        expect(menu, findsNothing);
        expect(find.bySemanticsLabel('更多'), findsOneWidget);
        await openMenu(tester);
        final m = tester.getRect(menu);
        final plus = rect(tester, 'composer-plus');
        expect(m.width, 300);
        expect(m.bottom, plus.top - 8);
        expect(m.right, plus.right);
        expect(find.text('附件…'), findsOneWidget);
        expect(find.text('也可以直接粘贴'), findsOneWidget);
        expect(find.text('在远端复制'), findsOneWidget);
        expect(find.text('Ctrl+C'), findsOneWidget);
        expect(find.text('按键 · 直接发给远端'), findsOneWidget);
        expect(find.text('收起'), findsOneWidget);
        // W9 order, reading left to right, row by row.
        final labels = ['Esc', 'Tab', '⌘', '⌥', '删除', '←', '↓', '↑', '→', '回车'];
        final pos = [for (final l in labels) tester.getCenter(find.text(l))];
        for (var i = 1; i < pos.length; i++) {
          final sameRow = (pos[i].dy - pos[i - 1].dy).abs() < 1;
          expect(sameRow ? pos[i].dx > pos[i - 1].dx : pos[i].dy > pos[i - 1].dy, isTrue, reason: labels[i]);
        }
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

      testWidgets('plus menu opens up from a panel at the bottom', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        expect(tester.getRect(menu).bottom, lessThanOrEqualTo(rect(tester, 'composer-plus').top));
      });

      testWidgets('plus menu opens down from a panel near the top', (tester) async {
        big(tester);
        es.profiles.setComposerAt('Notes', 'Notes', const InputPoint(0.5, 200));
        rs.setProfile(es.profiles.resolve('Notes'));
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        final m = tester.getRect(menu);
        final plus = rect(tester, 'composer-plus');
        final host = rect(tester, 'host');
        expect(m.top, plus.bottom + 8);
        expect(m.right, plus.right);
        expect(m.top, greaterThanOrEqualTo(host.top));
        expect(m.bottom, lessThanOrEqualTo(host.bottom));
      });

      testWidgets('the copy shortcut reads ⌘C on macOS', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        expect(find.text('⌘C'), findsOneWidget);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

      testWidgets('keys go to A in W9 order; ⌘ sticks for one key; the menu stays open', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        await tester.tap(find.text('⌘'));
        await tester.pump();
        await tester.tap(find.text('Tab'));
        await tester.pump();
        await tester.tap(find.text('Tab'));
        await tester.pump();
        expect(callsOf('key'), [
          equals({'sid': 1, 'keyCode': 48, 'modifiers': 1048576}),
          equals({'sid': 1, 'keyCode': 48, 'modifiers': 0}),
        ]);
        expect(menu, findsOneWidget);
        await tester.tap(find.text('→'));
        await tester.pump();
        expect(callsOf('key').last, equals({'sid': 1, 'keyCode': 124, 'modifiers': 0}));
      });

      testWidgets('closing the menu lets go of an armed ⌘ (m1)', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        for (final close in ['outside', 'plus']) {
          await openMenu(tester);
          await tester.tap(find.text('⌘'));
          await tester.pump();
          if (close == 'outside') {
            await tester.tapAt(const Offset(5, 5));
          } else {
            await tester.tap(find.byKey(const Key('composer-plus')));
          }
          await tester.pump();
          expect(menu, findsNothing, reason: close);
          await openMenu(tester);
          port.calls.clear();
          await tester.tap(find.text('Tab'));
          await tester.pump();
          expect(callsOf('key').single, equals({'sid': 1, 'keyCode': 48, 'modifiers': 0}), reason: close);
          await tester.tapAt(const Offset(5, 5));
          await tester.pump();
        }
      });

      testWidgets('在远端复制 sends ⌘C and the hint line says 已复制', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        await tester.tap(find.text('在远端复制'));
        await tester.pump();
        expect(callsOf('key').single, equals({'sid': 1, 'keyCode': 8, 'modifiers': 1048576}));
        expect(menu, findsNothing);
        expect(find.descendant(of: hint, matching: find.text('已复制')), findsOneWidget);
        await tester.pump(const Duration(seconds: 4));
      });

      testWidgets('附件… asks the runner and the menu closes', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        await tester.tap(find.text('附件…'));
        await tester.pump();
        expect(callsOf('composer_attach').single, equals({'sid': 1}));
        expect(menu, findsNothing);
      });

      testWidgets('收起 closes the panel and keeps the text', (tester) async {
        big(tester);
        rs.composer.setDraft('草稿');
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        await tester.tap(find.text('收起'));
        await tester.pump();
        await tester.pump();
        expect(menu, findsNothing);
        expect(find.byKey(const Key('composer-panel')), findsNothing);
        expect(rs.composer.open, isFalse);
        expect(rs.composer.draft, '草稿');
      });

      testWidgets('the sticky keys and the menu never carry over to another session', (tester) async {
        big(tester);
        final rs2 = RemoteSession(2, 'Notes');
        addTearDown(rs2.dispose);
        rs2.composer.open = true;
        await tester.pumpWidget(layer());
        await tester.pump();
        await openMenu(tester);
        await tester.tap(find.text('⌘'));
        await tester.pump();
        await tester.pumpWidget(layer(s: rs2));
        await tester.pump();
        expect(menu, findsNothing);
        await openMenu(tester);
        await tester.tap(find.text('←'));
        await tester.pump();
        expect(callsOf('key').single, equals({'sid': 2, 'keyCode': 123, 'modifiers': 0}));
      });

      testWidgets('hint line: A on an input method, accent, a tap switches to English', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        expect(hint, findsNothing);
        rs.apply(const InputSourceEvent(1, 'im', '拼音', false));
        await tester.pump();
        const line = '远端在用输入法 拼音，发送前会切到英文 · 点按现在就切';
        expect(find.descendant(of: hint, matching: find.text(line)), findsOneWidget);
        final style = tester.widget<Text>(find.text(line)).style!;
        expect(style.color, RappTokens.of(tester.element(hint)).accent);
        expect(style.fontWeight, FontWeight.w600);
        await tester.tap(find.text(line));
        await tester.pump();
        expect(callsOf('select_input').single, equals({'sid': 1, 'id': ''}));
        rs.apply(const InputSourceEvent(1, 'ascii', 'ABC', true));
        await tester.pump();
        expect(find.text(line), findsNothing);
        expect(hint, findsNothing);
      });

      testWidgets('hint line: an upload shows its progress with 取消', (tester) async {
        big(tester);
        rs.apply(const TransferStatusEvent(1, '上传 1/2 · a.txt'));
        await tester.pumpWidget(layer());
        await tester.pump();
        expect(find.descendant(of: hint, matching: find.text('上传 1/2 · a.txt')), findsOneWidget);
        await tester.tap(find.descendant(of: hint, matching: find.text('取消')));
        expect(callsOf('cancel_transfer').single, equals({'sid': 1}));
      });

      testWidgets('hint line on a narrow stage: long texts ellipsize, nothing overflows (m4)', (tester) async {
        big(tester);
        rs.apply(TransferStatusEvent(1, '上传 1/2 · ${'很长的文件名' * 10}.txt'));
        rs.apply(const InputSourceEvent(1, 'im', '拼音', false));
        await tester.pumpWidget(wrap(SizedBox(
            width: 360, height: 700, child: Stack(children: composerLayer(state: es, session: rs, port: port)))));
        await tester.pump();
        rs.composer.note('已贴入 ${'一张很大的图' * 10}');
        await tester.pump();
        expect(tester.takeException(), isNull);
        for (final t in tester.widgetList<Text>(find.descendant(of: hint, matching: find.byType(Text)))) {
          if (t.data == '取消') continue;
          expect(t.maxLines, 1, reason: t.data);
          expect(t.overflow, TextOverflow.ellipsis, reason: t.data);
        }
        expect(find.descendant(of: hint, matching: find.text('取消')), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
      });

      testWidgets('hint line: a paste or attach note shows and goes', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        rs.composer.apply(const PasteResult(status: '已贴入 1 张图'));
        await tester.pump();
        expect(find.descendant(of: hint, matching: find.text('已贴入 1 张图')), findsOneWidget);
        await tester.pump(const Duration(seconds: 6));
        expect(hint, findsNothing);
      });

      testWidgets('hint line is gone when nothing is going on', (tester) async {
        big(tester);
        await tester.pumpWidget(layer());
        await tester.pump();
        expect(hint, findsNothing);
      });
    });

    testWidgets('M3.1: the editor leaves room for the blocks row inside the box', (tester) async {
      big(tester);
      rs.composer.apply(const PasteResult(blocks: [BlockChip(1, '[图片 #1 10×20]'), BlockChip(2, '[文件 a 1 B]')]));
      rs.composer.setDraft(List.generate(40, (i) => 'line $i').join('\n'));
      await tester.pumpWidget(layer());
      await tester.pump();
      final box = rect(tester, 'composer-box');
      expect(box.height, lessThanOrEqualTo(350));
      final chip = tester.getRect(find.text('[图片 #1 10×20]'));
      final f = tester.getRect(fieldFinder);
      expect(chip.bottom, lessThanOrEqualTo(f.top));
      expect(f.bottom, lessThanOrEqualTo(box.bottom));
      expect(f.height, greaterThanOrEqualTo(48));
    });

    testWidgets('M3.1: a self-sizing editor is handed what the blocks row leaves, at least 48', (tester) async {
      final ed = FakeEditor()..selfSizing = true;
      Widget withEditor() => wrap(SizedBox(
          width: 720, child: ComposerPanel(state: es, session: rs, port: port, maxHeight: 350, editor: () => ed)));
      await tester.pumpWidget(withEditor());
      await tester.pump();
      expect(ed.lastMaxHeight, 348); // 350 less the border
      rs.composer.apply(const PasteResult(blocks: [BlockChip(1, '[图片 #1 10×20]'), BlockChip(2, '[文件 a 1 B]')]));
      await tester.pump();
      final row = tester.getSize(find.byType(SingleChildScrollView)).height;
      expect(row, greaterThan(0));
      expect(ed.lastMaxHeight, 348 - row);
      final box = rect(tester, 'composer-box');
      final edRect = tester.getRect(find.byKey(const Key('fake-editor')));
      expect(box.height, lessThanOrEqualTo(350));
      expect(edRect.height + row, lessThanOrEqualTo(box.height - 2));
    });

    testWidgets('M3.1: the editor is never handed under one line', (tester) async {
      final ed = FakeEditor()..selfSizing = true;
      rs.composer.apply(const PasteResult(blocks: [BlockChip(1, '[图片 #1 10×20]')]));
      await tester.pumpWidget(wrap(SizedBox(
          width: 600, child: ComposerPanel(state: es, session: rs, port: port, maxHeight: 60, editor: () => ed))));
      await tester.pump();
      expect(ed.lastMaxHeight, 48);
    });

    testWidgets('many failed rows scroll; the hint line, the editor and 发送 stay on stage (I2)', (tester) async {
      big(tester);
      for (var i = 0; i < 8; i++) {
        rs.composer.setDraft('row $i');
        await rs.composer.submit();
        rs.composer.done(0, 'boom');
      }
      rs.composer.note('已粘贴');
      await tester.pumpWidget(wrap(SizedBox(
          key: const Key('host'),
          width: 800,
          height: 400,
          child: Stack(children: composerLayer(state: es, session: rs, port: port)))));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final host = rect(tester, 'host');
      bool inside(Rect r) => host.contains(r.topLeft) && host.contains(r.bottomRight - const Offset(0.01, 0.01));
      expect(inside(rect(tester, 'composer-send')), isTrue);
      expect(inside(rect(tester, 'composer-hint')), isTrue);
      expect(inside(tester.getRect(fieldFinder)), isTrue);
      await tester.enterText(fieldFinder, 'z');
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pump();
      expect(callsOf('composer_send').last['pieces'], [
        {'text': 'z'},
      ]);
      rs.composer.done(1, null);
      await tester.pump();
      // The rows open at the bottom: the last one sits right above the hint line.
      expect(tester.getRect(find.text('row 7')).bottom, lessThanOrEqualTo(rect(tester, 'composer-hint').top));
      expect(inside(tester.getRect(find.text('row 7'))), isTrue);
      await tester.pump(const Duration(seconds: 5)); // the note and the idle copy
    });

    testWidgets('M3.2: a long failure ellipsizes and 重试 / 放回输入框 stay', (tester) async {
      await tester.pumpWidget(
          wrap(SizedBox(width: 600, child: ComposerPanel(state: es, session: rs, port: port, maxHeight: 300))));
      await tester.pump();
      await tester.enterText(fieldFinder, 'hello');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      rs.apply(ComposerStateEvent(1, done: ComposerDone(0, '失败' * 100)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('放回输入框'), findsOneWidget);
    });
  });

  group('stage', () {
    RemoteWindow rw(int id, double w, double h) => RemoteWindow(
          id: id,
          parent: 0,
          kind: WindowKind.normal,
          title: 'w$id',
          rect: Rect.fromLTWH(0, 0, w, h),
          titleBar: 28,
          resizable: true,
          focused: true,
          texture: 42,
          visible: const Rect.fromLTWH(0, 0, 1, 1),
        );

    Future<void> openEmbedded(WidgetTester tester, {int sid = 1, String app = 'Safari'}) async {
      await tester.runAsync(() async {
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({
              'event': 'opened', 'sid': sid, 'id': m['id'], 'app': m['app'], 'path': 'lan',
              'port': 5000 + sid, 'token': 'tk', 'req': m['req'],
            });
          }
        };
        es.openOrSwitch('111', app, app);
        for (var i = 0; i < 4; i++) {
          await flush();
        }
      });
      await tester.pump();
    }

    testWidgets('opening the composer does not resize A', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(width: 800, height: 600, child: Stage(state: es))));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 800, 628)]));
      await tester.pump();
      await tester.pump();
      final before = tester.getSize(find.byKey(const Key('stage')));
      port.calls.removeWhere((c) => c.$1 == 'resize');
      expect(find.byType(ComposerPanel), findsNothing);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ComposerPanel), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('stage'))), before);
      expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
      // R18: the draft and open state are the session's.
      expect(es.currentRemote!.composer.open, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ComposerPanel), findsNothing);
      expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
    });

    // Like MainWindow: a focused Focus above everything, and a CallbackShortcuts Esc (fullscreen).
    var escs = 0;
    var stageSize = const Size(800, 600);
    Widget mainLike() => CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => escs++},
          child: Focus(
              autofocus: true,
              child: SizedBox(width: stageSize.width, height: stageSize.height, child: Stage(state: es))),
        );

    // [reduced]: the platform asks for reduced motion.
    Future<void> showPicture(WidgetTester tester, {bool reduced = false}) async {
      escs = 0;
      stageSize = const Size(800, 600);
      await tester.pumpWidget(wrap(mainLike(), disableAnimations: reduced));
      await tester.pump();
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 800, 628)]));
      await tester.pump();
      es.focusPicture(1);
      await tester.pump();
    }

    double top(WidgetTester tester) => tester.getTopLeft(find.byType(Picture)).dy;

    Rect panelRect(WidgetTester tester) => tester.getRect(find.byKey(const Key('composer-panel')));
    final grip = find.byKey(const Key('composer-grip'));

    Future<void> openPanel(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pumpAndSettle();
    }

    // One touch drag on the grip, pumping after each move.
    Future<void> dragGrip(WidgetTester tester, List<Offset> moves) async {
      final g = await tester.startGesture(tester.getCenter(grip));
      for (final m in moves) {
        await g.moveBy(m);
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      await tester.pump(kDoubleTapTimeout); // the grip also waits for a second tap
    }

    // A compose letter (type-to-compose): the editor takes the caret, the picture lets go of the
    // keys, and only then the runner is asked to replay the letter.
    Future<void> composeKey(WidgetTester tester) async {
      port.calls.clear();
      port.emit(const ComposeKeyEvent(1));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final names = [for (final c in port.calls) c.$1];
      expect(es.currentRemote!.composer.editorFocused, isTrue);
      expect(es.pictureFocused, isNull);
      expect(names.where((m) => m == 'compose_replay').length, 1);
      final blur = port.calls.indexWhere((c) => c.$1 == 'picture_focus' && c.$2['sid'] == null);
      expect(blur, greaterThanOrEqualTo(0));
      expect(blur, lessThan(names.indexOf('compose_replay')));
      expect(port.calls.firstWhere((c) => c.$1 == 'compose_replay').$2, {'sid': 1});
    }

    testWidgets('compose_key: caret in the editor, picture blurred, then replay', (tester) async {
      await showPicture(tester);
      expect(find.byType(ComposerPanel), findsNothing);
      await composeKey(tester);
      expect(find.byType(ComposerPanel), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('compose_key with the panel open but the picture focused', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      es.focusPicture(1);
      await tester.pump();
      expect(es.pictureFocused, 1);
      await composeKey(tester);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('no replay without compose_key', (tester) async {
      await showPicture(tester);
      port.calls.clear();
      await openPanel(tester);
      expect(port.calls.where((c) => c.$1 == 'compose_replay'), isEmpty);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('opening, growing and closing never move the picture; A is never resized', (tester) async {
      await showPicture(tester);
      final y0 = top(tester);
      final size0 = tester.getSize(find.byKey(const Key('stage')));
      port.calls.removeWhere((c) => c.$1 == 'resize');
      await openPanel(tester);
      expect(top(tester), y0);
      es.currentRemote!.composer.setDraft(List.generate(10, (i) => 'line $i').join('\n'));
      await tester.pumpAndSettle();
      expect(top(tester), y0);
      expect(tester.getSize(find.byKey(const Key('stage'))), size0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(top(tester), y0);
      expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
    });

    testWidgets('a click on the picture with the panel open lands as with it closed', (tester) async {
      List<Map<String, Object?>> downs() =>
          port.calls.where((c) => c.$1 == 'mouse' && c.$2['kind'] == 'down').map((c) => c.$2).toList();
      await showPicture(tester);
      final g0 = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g0.down(tester.getCenter(find.byType(Picture)));
      await g0.up();
      await tester.pump();
      final plain = downs().single;
      port.calls.clear();
      await openPanel(tester);
      port.calls.clear();
      final seen = tester.getCenter(find.byType(Picture));
      expect(seen.dy, 300);
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.down(seen);
      await g.up();
      await tester.pump();
      final open = downs().single;
      expect(open['x'], plain['x']);
      expect(open['y'], plain['y']);
    });

    testWidgets('the panel starts bottom centre, 8 up, the grip above it', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      final p = panelRect(tester);
      expect(p.bottom, 600 - 8);
      expect(p.center.dx, 400);
      final g = tester.getRect(grip);
      expect(g.width, greaterThanOrEqualTo(48));
      expect(g.height, greaterThanOrEqualTo(20));
      expect(g.bottom, p.top);
      expect(g.center.dx, 400);
    });

    testWidgets('dragging the grip moves the panel and saves once on release', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      var saves = 0;
      es.profiles.addListener(() => saves++);
      final g = await tester.startGesture(tester.getCenter(grip));
      for (final m in const [Offset(-10, -100), Offset(-5, -50), Offset(-5, -50)]) {
        await g.moveBy(m);
        await tester.pump();
      }
      expect(saves, 0);
      expect(panelRect(tester).bottom, 392);
      expect(panelRect(tester).center.dx, 380);
      await g.up();
      await tester.pump();
      expect(saves, 1);
      expect(es.profiles.resolve('Safari').composerAt, InputPoint.at(const Offset(380, 392), const Size(800, 600)));
      expect(panelRect(tester).bottom, 392);
      expect(panelRect(tester).center.dx, 380);
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets('double-tap on the grip goes back to the default', (tester) async {
      es.profiles.setComposerAt('Safari', 'Safari', const InputPoint(0.5, 100));
      await showPicture(tester);
      await openPanel(tester);
      expect(panelRect(tester).bottom, 100);
      expect(panelRect(tester).center.dx, 400);
      await tester.tap(grip);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(grip);
      await tester.pumpAndSettle();
      expect(es.profiles.resolve('Safari').composerAt, isNull);
      expect(panelRect(tester).bottom, 592);
      expect(panelRect(tester).center.dx, 400);
      expect(fieldFocused(tester), isTrue);
    });

    testWidgets('a drag keeps the text and the caret', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      await tester.enterText(fieldFinder, 'keep');
      await tester.pump();
      await dragGrip(tester, const [Offset(0, -150), Offset(0, -50)]);
      expect(panelRect(tester).bottom, 392);
      expect(text(tester), 'keep');
      expect(fieldFocused(tester), isTrue);
    });

    testWidgets('no dead zone past the edge', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      // 720 wide on 800: the centre can go from 368 to 432.
      await dragGrip(tester, const [Offset(2000, 0), Offset(-50, 0)]);
      expect(panelRect(tester).center.dx, 382);
      expect(panelRect(tester).bottom, 592);
    });

    testWidgets('a touch held still on the grip, then moved, still drags (no long-press tooltip)', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      final g = await tester.startGesture(tester.getCenter(grip));
      await tester.pump(const Duration(milliseconds: 800));
      await g.moveBy(const Offset(0, -100));
      await tester.pump();
      await g.moveBy(const Offset(0, -100));
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.pump(kDoubleTapTimeout);
      expect(panelRect(tester).bottom, 392);
      expect(find.text('拖动；双击回到底部居中'), findsNothing);
    });

    testWidgets('a two-finger trackpad scroll over the grip does not move the panel', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      var saves = 0;
      es.profiles.addListener(() => saves++);
      final at = tester.getCenter(grip);
      final g = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await g.panZoomStart(at);
      await tester.pump();
      await g.panZoomUpdate(at, pan: const Offset(0, -100));
      await tester.pump();
      await g.panZoomUpdate(at, pan: const Offset(0, -200));
      await tester.pump();
      await g.panZoomEnd();
      await tester.pump();
      await tester.pump(kDoubleTapTimeout);
      expect(panelRect(tester).bottom, 592);
      expect(saves, 0);
    });

    testWidgets('each app has its own place', (tester) async {
      es.profiles.setComposerAt('Safari', 'Safari', const InputPoint(0.25, 100));
      await showPicture(tester);
      await openPanel(tester);
      expect(panelRect(tester).bottom, 100);
      await openEmbedded(tester, sid: 2, app: 'Notes');
      port.emit(const ReadyEvent(2, 'Notes'));
      port.emit(WindowsEvent(2, [rw(6, 800, 628)]));
      await tester.pump();
      await tester.pump();
      expect(es.currentRemote!.appId, 'Notes');
      // Open or not is the session's (R18): Notes' panel starts closed.
      expect(find.byKey(const Key('composer-panel')), findsNothing);
      await openPanel(tester);
      expect(panelRect(tester).bottom, 592);
      expect(panelRect(tester).center.dx, 400);
    });

    testWidgets('a session switch mid-drag saves for neither app', (tester) async {
      await showPicture(tester);
      await openEmbedded(tester, sid: 2, app: 'Notes');
      port.emit(const ReadyEvent(2, 'Notes'));
      port.emit(WindowsEvent(2, [rw(6, 800, 628)]));
      await tester.pump();
      await openPanel(tester);
      await openEmbedded(tester, sid: 1, app: 'Safari');
      await tester.pump();
      expect(es.currentRemote!.appId, 'Safari');
      await openPanel(tester);
      final g = await tester.startGesture(tester.getCenter(grip));
      await g.moveBy(const Offset(0, -100));
      await tester.pump();
      await openEmbedded(tester, sid: 2, app: 'Notes');
      await tester.pump();
      expect(es.currentRemote!.appId, 'Notes');
      await g.moveBy(const Offset(0, -50));
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.pump(kDoubleTapTimeout);
      expect(es.profiles.resolve('Notes').composerAt, isNull);
      expect(es.profiles.resolve('Safari').composerAt, isNull);
      expect(panelRect(tester).bottom, 592);
    });

    testWidgets('a drag that ends where it started writes nothing', (tester) async {
      await showPicture(tester);
      await openPanel(tester);
      var saves = 0;
      es.profiles.addListener(() => saves++);
      await dragGrip(tester, const [Offset(0, -100), Offset(0, 100)]);
      expect(panelRect(tester).bottom, 592);
      expect(saves, 0);
      expect(es.profiles.mine, isEmpty);
    });

    testWidgets('a smaller stage clamps the panel without rewriting its place; it comes back', (tester) async {
      const at = InputPoint(0.5, 500);
      es.profiles.setComposerAt('Safari', 'Safari', at);
      await showPicture(tester);
      await openPanel(tester);
      expect(panelRect(tester).bottom, 500);
      var saves = 0;
      es.profiles.addListener(() => saves++);
      stageSize = const Size(800, 400);
      await tester.pumpWidget(wrap(mainLike()));
      await tester.pump();
      expect(panelRect(tester).bottom - tester.getTopLeft(find.byType(Stage)).dy, 392);
      stageSize = const Size(800, 600);
      await tester.pumpWidget(wrap(mainLike()));
      await tester.pump();
      expect(panelRect(tester).bottom, 500);
      expect(saves, 0);
      expect(es.profiles.resolve('Safari').composerAt, at);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('the panel grows upward; its bottom stays', (tester) async {
      es.profiles.setComposerAt('Safari', 'Safari', const InputPoint(0.5, 400));
      await showPicture(tester);
      await openPanel(tester);
      final before = panelRect(tester);
      es.currentRemote!.composer.setDraft(List.generate(10, (i) => 'line $i').join('\n'));
      await tester.pumpAndSettle();
      final after = panelRect(tester);
      expect(after.height, greaterThan(before.height));
      expect(after.bottom, before.bottom);
    });

    testWidgets('no lift over a detached placeholder', (tester) async {
      await showPicture(tester);
      port.emit(const DetachedEvent(1, true));
      await tester.pump();
      expect(find.byType(Picture), findsNothing);
      final before = tester.getTopLeft(find.byKey(const Key('stage'))).dy;
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composer-panel')), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(const Key('stage'))).dy, before);
    });

    testWidgets('opening the composer takes the caret from the picture', (tester) async {
      await showPicture(tester);
      port.calls.clear();
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump();
      expect(fieldFocused(tester), isTrue);
      expect(es.pictureFocused, isNull);
      expect(port.calls.where((c) => c.$1 == 'picture_focus').map((c) => c.$2), [
        equals({'sid': null}),
      ]);
    });

    testWidgets('Esc collapses and keeps the text (W6); the window Esc never sees it', (tester) async {
      await showPicture(tester);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump();
      await tester.enterText(fieldFinder, 'keep');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('composer-panel')), findsNothing);
      expect(escs, 0);
      // Collapse is a copy point: the draft has the text without waiting for the idle copy.
      expect(es.currentRemote!.composer.draft, 'keep');
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      expect(text(tester), 'keep');
    });

    testWidgets('a tap outside the plus menu closes it without reaching A; the next tap does', (tester) async {
      await showPicture(tester);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-plus')));
      await tester.pump();
      final menu = find.byKey(const Key('composer-plus-menu'));
      expect(menu, findsOneWidget);
      port.calls.clear();
      final spot = tester.getTopLeft(find.byType(Picture)) + const Offset(100, 100);
      await tester.tapAt(spot);
      await tester.pump();
      expect(menu, findsNothing);
      expect(port.calls.where((c) => c.$1 == 'mouse'), isEmpty);
      await tester.tapAt(spot);
      await tester.pump();
      expect(port.calls.where((c) => c.$1 == 'mouse'), isNotEmpty);
    });

    testWidgets('the ＋ menu opens the history and 放进输入框 closes it', (tester) async {
      await showPicture(tester);
      es.history.add({
        'id': '01A',
        'ts': '2026-11-15T09:00:00+09:00',
        'kind': 'sent',
        'from': {'id': 'dev1', 'name': 'x'},
        'host': {'id': '111', 'name': 'mini'},
        'app': {'id': 'Safari', 'name': 'Safari'},
        'session': '111/Safari',
        'text': '回头再看这段',
      });
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-plus')));
      await tester.pump();
      await tester.tap(find.text('输入历史'));
      await tester.pump();
      expect(find.byKey(const Key('composer-plus-menu')), findsNothing);
      expect(find.byType(InputHistoryList), findsOneWidget);
      expect(find.byKey(const Key('history-01A')), findsOneWidget); // this session's, by default
      await tester.tap(find.byKey(const Key('put-01A')));
      await tester.pumpAndSettle();
      expect(find.byType(InputHistoryList), findsNothing);
      expect(es.currentRemote!.composer.open, isTrue);
      expect(text(tester), contains('回头再看这段'));
    });

    testWidgets('Esc with the plus menu open closes the panel and the menu', (tester) async {
      await showPicture(tester);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-plus')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('composer-plus-menu')), findsNothing);
      expect(find.byKey(const Key('composer-panel')), findsNothing);
    });

    testWidgets('drafts stay with their session across a switch', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(width: 800, height: 600, child: Stage(state: es))));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 800, 628)]));
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.enterText(fieldFinder, 'one');
      final one = es.currentRemote!;

      await openEmbedded(tester, sid: 2, app: 'Notes');
      port.emit(const ReadyEvent(2, 'Notes'));
      port.emit(WindowsEvent(2, [rw(6, 800, 628)]));
      await tester.pump();
      final two = es.currentRemote!;
      expect(two.sid, 2);
      expect(one.composer.draft, 'one'); // copied at the switch, not 1 s later
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      expect(text(tester), isEmpty);
      await tester.enterText(fieldFinder, 'two');

      es.select('111/Safari');
      await tester.pump();
      expect(es.currentRemote, same(one));
      expect(text(tester), 'one');
      expect(two.composer.draft, 'two');
    });

    testWidgets('a clip insert focuses the field, even over a focused picture', (tester) async {
      await showPicture(tester);
      port.emit(const ComposerInsertEvent(1, PasteResult(text: 'a')));
      await tester.pump();
      await tester.pump();
      expect(fieldFocused(tester), isTrue);
      expect(es.pictureFocused, isNull);

      // Already open, the picture clicked with the mouse meanwhile (Flutter's focus really moves
      // to it): the insert brings the caret back.
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.down(tester.getCenter(find.byType(Picture)));
      await g.up();
      await tester.pump();
      expect(es.pictureFocused, 1);
      expect(fieldFocused(tester), isFalse);
      port.emit(const ComposerInsertEvent(1, PasteResult(text: 'b')));
      // MainState listens to the port from setUp, outside the test's fake zone: the focus change
      // the event asks for is a real-zone microtask, which pump alone does not run.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();
      expect(fieldFocused(tester), isTrue);
      expect(es.pictureFocused, isNull);
      expect(text(tester), 'ab');
    });

    testWidgets('Esc and Enter while composing stay with the input method', (tester) async {
      await showPicture(tester);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.tap(fieldFinder);
      await tester.pump();
      final m = es.currentRemote!.composer;
      field(tester).controller!.value = const TextEditingValue(
          text: 'ni', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(escs, 0);
      expect(m.open, isTrue);
      expect(text(tester), 'ni');
      expect(callsOf('composer_send'), isEmpty);
      // Not composing: Esc is the panel's (collapse, the text stays), never the window's.
      field(tester).controller!.value =
          const TextEditingValue(text: 'ni', selection: TextSelection.collapsed(offset: 2));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(m.open, isFalse);
      expect(escs, 0);
      expect(m.draft, 'ni');
    });

    testWidgets('a clip insert opens the composer with it', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(width: 800, height: 600, child: Stage(state: es))));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 800, 628)]));
      await tester.pump();
      port.emit(const ComposerInsertEvent(1, PasteResult(text: 'from A')));
      await tester.pump();
      expect(find.byType(ComposerPanel), findsOneWidget);
      expect(text(tester), 'from A');
    });

    // R2/R3: records of 111/Safari, given newest first.
    var recId = 0;
    void remember(List<String> newestFirst, {String session = '111/Safari'}) {
      for (final text in newestFirst.reversed) {
        recId++;
        es.history.add({
          'v': 1,
          'id': '01REC${recId.toString().padLeft(4, '0')}',
          'ts': '2026-11-14T10:${recId.toString().padLeft(2, '0')}:00+09:00',
          'kind': 'sent',
          'from': {'id': 'dev1', 'name': 'b'},
          'host': {'id': '111', 'name': 'mini'},
          'app': {'id': 'Safari', 'name': 'Safari'},
          'session': session,
          'run': 'r',
          'projects': <String>[],
          'text': text,
          'blocks': <Object>[],
          'source': 'typed',
        });
      }
    }

    Future<void> liveStage(WidgetTester tester) async {
      await tester.pumpWidget(wrap(SizedBox(width: 800, height: 600, child: Stage(state: es))));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 800, 628)]));
      await tester.pump();
    }

    // The live session's panel alone, on a FakeEditor.
    Future<FakeEditor> livePanel(WidgetTester tester) async {
      await openEmbedded(tester);
      final ed = FakeEditor();
      final s = es.currentRemote!..composer.open = true;
      await tester.pumpWidget(wrap(SizedBox(
          width: 720, child: ComposerPanel(state: es, session: s, port: port, maxHeight: 300, editor: () => ed))));
      await tester.pump();
      return ed;
    }

    testWidgets('up on an empty editor brings the last one, again the one before, down goes back to empty',
        (tester) async {
      remember(['c', 'b', 'a']);
      await liveStage(tester);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.pump();
      expect(fieldFocused(tester), isTrue);
      Future<String> key(LogicalKeyboardKey k) async {
        await tester.sendKeyEvent(k);
        await tester.pump();
        return text(tester);
      }

      expect(await key(LogicalKeyboardKey.arrowUp), 'c');
      expect(await key(LogicalKeyboardKey.arrowUp), 'b');
      expect(await key(LogicalKeyboardKey.arrowDown), 'c');
      expect(await key(LogicalKeyboardKey.arrowDown), '');
      // Down on an empty editor that is not browsing: nothing.
      expect(await key(LogicalKeyboardKey.arrowDown), '');
      // Up to the oldest, and up again stays there.
      expect(await key(LogicalKeyboardKey.arrowUp), 'c');
      expect(await key(LogicalKeyboardKey.arrowUp), 'b');
      expect(await key(LogicalKeyboardKey.arrowUp), 'a');
      expect(await key(LogicalKeyboardKey.arrowUp), 'a');
      expect(await key(LogicalKeyboardKey.arrowDown), 'b');
    });

    testWidgets('once edited, up and down move the caret', (tester) async {
      remember(['c', 'b', 'a']);
      final ed = await livePanel(tester);
      final h = ed.handlers!;
      expect(h.onArrow(true), isTrue);
      expect(ed.value, 'c');
      ed.value = 'cx';
      h.onChanged();
      await tester.pump();
      expect(h.onArrow(true), isFalse);
      expect(h.onArrow(false), isFalse);
      expect(ed.value, 'cx');

      // Back to empty by hand: up brings the last one again.
      ed.value = '';
      h.onChanged();
      await tester.pump();
      expect(h.onArrow(true), isTrue);
      expect(ed.value, 'c');
    });

    testWidgets('up on a draft never replaces it', (tester) async {
      remember(['c']);
      final ed = await livePanel(tester);
      ed.value = '我写了一半';
      ed.handlers!.onChanged();
      await tester.pump();
      expect(ed.handlers!.onArrow(true), isFalse);
      expect(ed.handlers!.onArrow(false), isFalse);
      expect(ed.value, '我写了一半');
    });

    testWidgets('up with no history is not taken', (tester) async {
      remember(['elsewhere'], session: '111/Notes');
      final ed = await livePanel(tester);
      expect(ed.handlers!.onArrow(true), isFalse);
      expect(ed.handlers!.onArrow(false), isFalse);
      expect(ed.value, '');
    });

    testWidgets('the hint says ↑ when there is history', (tester) async {
      await liveStage(tester);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      expect(find.text('写给 Safari'), findsOneWidget);
      expect(find.text('写给 Safari · ↑ 上一条'), findsNothing);
      remember(['c']);
      await tester.pump();
      expect(find.text('写给 Safari · ↑ 上一条'), findsOneWidget);
      expect(find.text('写给 Safari'), findsNothing);
    });
  });
}
