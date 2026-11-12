import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
    es = MainState(hub: hub, configDir: tmp.path, prefs: UiPrefs(), port: port);
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

    testWidgets('an upload shows its status with a cancel', (tester) async {
      rs.apply(const TransferEvent(1, '上传 1/2 · a.txt'));
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
