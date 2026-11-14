import 'dart:io';

import 'package:rapp/paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/composer_bar.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/stage.dart';

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
    tmp = Directory.systemTemp.createTempSync('composer_bar_test');
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

  group('bar', () {
    late RemoteSession rs;

    setUp(() {
      rs = RemoteSession(1, 'Safari', onDropBlock: (n) => port.composerDropBlock(1, n));
      rs.composer.open = true;
    });
    tearDown(() => rs.dispose());

    Widget bar() => SizedBox(width: 900, child: ComposerBar(state: es, session: rs, port: port));

    testWidgets('enter sends, shift-enter newlines, enter while composing does not send', (tester) async {
      await tester.pumpWidget(wrap(bar()));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final c = rs.composer.controller;

      c.value = const TextEditingValue(
          text: 'ni', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(callsOf('composer_send'), isEmpty);

      c.value = const TextEditingValue(text: 'a', selection: TextSelection.collapsed(offset: 1));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(c.text, 'a\n');
      expect(callsOf('composer_send'), isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      final sent = callsOf('composer_send');
      expect(sent.length, 1);
      expect(sent.single['sid'], 1);
      expect(sent.single['pieces'], [
        {'text': 'a\n'},
      ]);
    });

    group('with the input source and Return wired', () {
      late RemoteSession rs2;
      setUp(() {
        rs2 = RemoteSession(1, 'Safari',
            onReturn: () => port.key(1, 36, 0), onSelectInput: (id) => port.selectInput(1, id));
        rs2.composer.open = true;
      });
      tearDown(() => rs2.dispose());
      Widget bar2() => SizedBox(width: 900, child: ComposerBar(state: es, session: rs2, port: port));

      testWidgets('no input method chip until the host says', (tester) async {
        await tester.pumpWidget(wrap(bar2()));
        expect(find.byKey(const Key('remote-ime')), findsNothing);
        rs2.apply(const InputSourceEvent(1, 'im', '拼音', false));
        await tester.pump();
        expect(find.text('远端输入法：拼音'), findsOneWidget);
        await tester.tap(find.byKey(const Key('remote-ime')));
        expect(callsOf('select_input').single, {'sid': 1, 'id': ''});
        rs2.apply(const InputSourceEvent(1, 'abc', 'ABC', true));
        await tester.pump();
        expect(find.text('远端输入法：英文'), findsOneWidget);
        await tester.tap(find.byKey(const Key('remote-ime')));
        expect(callsOf('select_input').last, {'sid': 1, 'id': 'im'});
      });

      testWidgets('a send switches to English first; an empty Enter presses Return', (tester) async {
        await tester.pumpWidget(wrap(bar2()));
        rs2.apply(const InputSourceEvent(1, 'im', '拼音', false));
        await tester.tap(find.byType(TextField));
        await tester.pump();
        rs2.composer.text = 'hi';
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect([for (final c in port.calls) c.$1].where((m) => m == 'select_input' || m == 'composer_send'),
            ['select_input', 'composer_send']);
        rs2.apply(const ComposerStateEvent(1, done: ComposerDone(1, null)));
        await tester.pump();
        expect(rs2.composer.text, isEmpty);

        port.calls.clear();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(callsOf('key'), [
          {'sid': 1, 'keyCode': 36, 'modifiers': 0},
        ]);
        expect(callsOf('composer_send'), isEmpty);
        expect(find.text('已给远端发回车'), findsOneWidget);
        await tester.pump(const Duration(seconds: 5)); // the status line clears
      });
    });

    testWidgets('a tap while the input method composes cannot move the caret', (tester) async {
      await tester.pumpWidget(wrap(bar()));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final c = rs.composer.controller;
      final start = tester.getTopLeft(find.byType(EditableText)) + const Offset(1, 5);

      // fcitx5's preedit, arriving the way the platform delivers it.
      tester.testTextInput.updateEditingValue(const TextEditingValue(
          text: 'bu dui',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 0, end: 6)));
      await tester.pump();

      // A tap at the start of the text would re-anchor the preedit and double every letter.
      await tester.tapAt(start);
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.value.selection, const TextSelection.collapsed(offset: 6));
      expect(c.value.composing, const TextRange(start: 0, end: 6));
      expect(c.value.text, 'bu dui');

      // Composition over: taps place the caret again.
      tester.testTextInput.updateEditingValue(const TextEditingValue(
          text: '不对', selection: TextSelection.collapsed(offset: 2)));
      await tester.pump();
      await tester.tapAt(start);
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.value.selection, const TextSelection.collapsed(offset: 0));
    });

    testWidgets('keys row sends codes with sticky command', (tester) async {
      await tester.pumpWidget(wrap(bar()));
      await tester.tap(find.text('按键'));
      await tester.pump();
      await tester.tap(find.text('⌘'));
      await tester.pump();
      await tester.tap(find.text('←'));
      await tester.pump();
      await tester.tap(find.text('←'));
      await tester.pump();
      final keys = callsOf('key');
      expect(keys.length, 2);
      expect(keys[0], equals({'sid': 1, 'keyCode': 123, 'modifiers': 1048576}));
      expect(keys[1], equals({'sid': 1, 'keyCode': 123, 'modifiers': 0}));
    });

    testWidgets('tapping a block removes it', (tester) async {
      rs.composer.apply(const PasteResult(blocks: [BlockChip(1, '[图片 #1 10×20]'), BlockChip(2, '[文件 a 1 B]')]));
      await tester.pumpWidget(wrap(bar()));
      await tester.tap(find.text('[图片 #1 10×20]'));
      await tester.pump();
      expect(find.text('[图片 #1 10×20]'), findsNothing);
      expect(find.text('[文件 a 1 B]'), findsOneWidget);
      expect(callsOf('composer_drop_block'), [
        equals({'sid': 1, 'block': 1}),
      ]);
    });

    testWidgets('⌘V pastes what the runner answers at the cursor', (tester) async {
      port.pasteReply = {'text': 'hello'};
      await tester.pumpWidget(wrap(bar()));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      await tester.pump();
      expect(callsOf('composer_paste'), [
        equals({'sid': 1}),
      ]);
      expect(rs.composer.text, 'hello');
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
      await tester.pumpWidget(wrap(bar()));
      es.focusPicture(1);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(es.pictureFocused, isNull);
      expect(port.calls.last.$1, 'picture_focus');
      expect(port.calls.last.$2, equals({'sid': null}));
    });

    testWidgets('copy sends ⌘C to A and says so', (tester) async {
      await tester.pumpWidget(wrap(bar()));
      await tester.tap(find.text('复制'));
      await tester.pump();
      expect(callsOf('key').single, equals({'sid': 1, 'keyCode': 8, 'modifiers': 1048576}));
      expect(find.text('已复制'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('the keys row and sticky keys are per session', (tester) async {
      final rs2 = RemoteSession(2, 'Notes');
      addTearDown(rs2.dispose);
      rs2.composer.open = true;
      Widget layer(RemoteSession s) => wrap(SizedBox(
          width: 900, height: 400, child: Stack(children: composerLayer(state: es, session: s, port: port))));
      await tester.pumpWidget(layer(rs));
      await tester.tap(find.text('按键'));
      await tester.pump();
      await tester.tap(find.text('⌘'));
      await tester.pump();
      await tester.pumpWidget(layer(rs2));
      expect(find.text('←'), findsNothing);
      await tester.tap(find.text('按键'));
      await tester.pump();
      await tester.tap(find.text('←'));
      await tester.pump();
      expect(callsOf('key').single, equals({'sid': 2, 'keyCode': 123, 'modifiers': 0}));
    });

    testWidgets('no 「输入」 button and no bar while composerAllowed is false; both come back', (tester) async {
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
      rs.composer.text = '草稿';
      await tester.pumpWidget(wrap(SizedBox(
          width: 900, height: 400, child: Stack(children: composerLayer(state: es, session: rs, port: port)))));
      expect(find.byKey(const Key('composer-bar')), findsNothing);
      expect(find.byKey(const Key('composer-open')), findsNothing);
      rs.selectWindow(1);
      await tester.pump();
      expect(find.byKey(const Key('composer-bar')), findsOneWidget);
      expect(find.text('草稿'), findsOneWidget);
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

    testWidgets('an upload shows its status with a cancel', (tester) async {
      rs.apply(const TransferStatusEvent(1, '上传 1/2 · a.txt'));
      await tester.pumpWidget(wrap(bar()));
      expect(find.text('上传 1/2 · a.txt'), findsOneWidget);
      await tester.tap(find.text('取消'));
      expect(callsOf('cancel_transfer').single, equals({'sid': 1}));
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

    Future<void> openEmbedded(WidgetTester tester) async {
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
      expect(find.byType(ComposerBar), findsNothing);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ComposerBar), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('stage'))), before);
      expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
      // R18: the draft and open state are the session's.
      expect(es.currentRemote!.composer.open, isTrue);
      await tester.tap(find.text('收起'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ComposerBar), findsNothing);
      expect(port.calls.where((c) => c.$1 == 'resize'), isEmpty);
    });

    // Like MainWindow: a focused Focus above everything, and a CallbackShortcuts Esc (fullscreen).
    var escs = 0;
    Widget mainLike() => CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => escs++},
          child: Focus(autofocus: true, child: SizedBox(width: 800, height: 600, child: Stage(state: es))),
        );
    bool fieldFocused(WidgetTester tester) =>
        tester.widget<TextField>(find.byKey(const Key('composer-field'))).focusNode!.hasFocus;

    Future<void> showPicture(WidgetTester tester) async {
      escs = 0;
      await tester.pumpWidget(wrap(mainLike()));
      await tester.pump();
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 800, 628)]));
      await tester.pump();
      es.focusPicture(1);
      await tester.pump();
    }

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

    testWidgets('a clip insert focuses the field, even over a focused picture', (tester) async {
      await showPicture(tester);
      port.emit(const ComposerInsertEvent(1, PasteResult(text: 'a')));
      await tester.pump();
      await tester.pump();
      expect(fieldFocused(tester), isTrue);
      expect(es.pictureFocused, isNull);

      // Already open, the picture pressed meanwhile: the insert brings the caret back.
      es.focusPicture(1);
      await tester.pump();
      port.emit(const ComposerInsertEvent(1, PasteResult(text: 'b')));
      await tester.pump();
      await tester.pump();
      expect(fieldFocused(tester), isTrue);
      expect(es.pictureFocused, isNull);
      expect(es.currentRemote!.composer.text, 'ab');
    });

    testWidgets('Esc and Enter while composing stay with the input method', (tester) async {
      await showPicture(tester);
      await tester.tap(find.byKey(const Key('composer-open')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-field')));
      await tester.pump();
      final m = es.currentRemote!.composer;
      m.controller.value = const TextEditingValue(
          text: 'ni', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(escs, 0);
      expect(m.open, isTrue);
      expect(m.text, 'ni');
      expect(callsOf('composer_send'), isEmpty);
      // Not composing: Esc is the composer's (clear, then close), never the window's.
      m.controller.value = TextEditingValue.empty;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(m.open, isFalse);
      expect(escs, 0);
    });

    testWidgets('a clip insert opens the composer with it', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(width: 800, height: 600, child: Stage(state: es))));
      await openEmbedded(tester);
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [rw(5, 800, 628)]));
      await tester.pump();
      port.emit(const ComposerInsertEvent(1, PasteResult(text: 'from A')));
      await tester.pump();
      expect(find.byType(ComposerBar), findsOneWidget);
      expect(es.currentRemote!.composer.text, 'from A');
    });
  });
}
