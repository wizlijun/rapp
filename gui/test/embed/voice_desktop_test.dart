import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/flutter_editor.dart';
import 'package:rapp/embed/composer_panel.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/voice_desktop.dart';
import 'package:rapp/embed/voice_key_gate.dart';
import 'package:rapp/embed/voice_ring.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';
import '../ui/helpers.dart';
import 'voice_button_test.dart' show FakeVoice;

void main() {
  late FakeTransport t;
  late HubClient hub;
  late FakeSessionPort port;
  late MainState es;
  late Directory tmp;
  late RemoteSession rs;
  late FakeVoice voice;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('voice_desktop_test');
    t = FakeTransport();
    hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': '111', 'name': 'mini'},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    port = FakeSessionPort();
    voice = FakeVoice();
    es = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port, voice: voice);
    rs = RemoteSession(1, 'Safari');
  });

  tearDown(() {
    rs.dispose();
    es.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> goLive(WidgetTester tester) => tester.runAsync(() async {
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
          await Future<void>.delayed(Duration.zero);
        }
      });

  Widget layer({double width = 1000, bool reduced = false}) => wrap(
      SizedBox(
          key: const Key('stage'),
          width: width,
          height: 700,
          child: Stack(children: composerLayer(state: es, session: rs, port: port, editor: FlutterEditor.new))),
      disableAnimations: reduced);

  // macOS for the test; the override must be unset before the binding checks its invariants.
  void macTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        try {
          await body(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

  Future<void> view(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  final hold = find.byKey(const Key('voice-hold'));
  final open = find.byKey(const Key('composer-open'));
  List<Object?> sends() => [for (final c in port.calls) if (c.$1 == 'composer_send') c.$2['pieces']];

  Future<TestGesture> press(WidgetTester tester) async {
    final g = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    return g;
  }

  test('desktopPick inflates targets by 6', () {
    final cancel = Rect.fromLTWH(110, 40, 60, 24), edit = Rect.fromLTWH(10, 40, 60, 24);
    expect(desktopPick(const Offset(105, 50), cancel, edit), VoicePick.cancel);
    expect(desktopPick(const Offset(103, 50), cancel, edit), VoicePick.send);
    expect(desktopPick(const Offset(73, 50), cancel, edit), VoicePick.edit);
  });

  macTest('the row has 按住说话 rightmost on macOS', (tester) async {
    await view(tester);
    await tester.pumpWidget(layer());
    expect(hold, findsOneWidget);
    expect(tester.getCenter(hold).dx, greaterThan(tester.getCenter(open).dx));
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(layer(width: 999));
    expect(hold, findsNothing);
  });

  macTest('press shows 正在听… then send', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    final g = await press(tester);
    expect(find.text('正在听…'), findsOneWidget);
    expect(find.text('松手 发送'), findsOneWidget);
    voice.partial('你好');
    voice.stopResult = '你好';
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(sends(), [
      [
        {'text': '你好'}
      ]
    ]);
    expect(port.calls.last.$1, 'picture_focus');
    expect(port.calls.last.$2['sid'], 1);
    expect(port.calls.any((c) => c.$1 == 'voice_end' && c.$2['sid'] == 1), isTrue);
  });

  macTest('drag onto 取消 then release sends nothing', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    final g = await press(tester);
    await g.moveTo(tester.getCenter(find.byKey(const Key('voice-cancel'))));
    await tester.pump();
    expect(find.text('松手 取消'), findsOneWidget);
    voice.partial('你好');
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(sends(), isEmpty);
    expect(voice.cancelled, isTrue);
  });

  macTest('drag onto 编辑 opens the panel with the words', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    final g = await press(tester);
    await g.moveTo(tester.getCenter(find.byKey(const Key('voice-edit'))));
    await tester.pump();
    expect(find.text('松手 改一改再发'), findsOneWidget);
    voice.stopResult = '你好';
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(rs.composer.open, isTrue);
    expect(rs.composer.draft, endsWith('你好'));
  });

  macTest('Esc during a mouse hold cancels', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    final g = await press(tester);
    expect(find.text('正在听…'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(voice.cancelled, isTrue);
    expect(find.text('正在听…'), findsNothing);
    await g.up();
    await tester.pump();
  });

  macTest('hotkey start and release send', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    es.voiceKey(1, VoiceKeyPhase.start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('正在听…'), findsOneWidget);
    voice.stopResult = '好的';
    es.voiceKey(1, VoiceKeyPhase.release);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(sends(), hasLength(1));
    expect(find.text('正在听…'), findsNothing);
  });

  macTest('a hotkey start is ignored while the panel is open', (tester) async {
    await view(tester);
    rs.composer.open = true;
    await tester.pumpWidget(layer());
    es.voiceKey(1, VoiceKeyPhase.start);
    await tester.pump();
    expect(voice.starts, 0);
  });

  macTest('disposing during a hotkey hold sends voice_end', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    es.voiceKey(1, VoiceKeyPhase.start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('正在听…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(port.calls.any((c) => c.$1 == 'voice_end' && c.$2['sid'] == 1), isTrue);
    expect(voice.cancelled, isTrue);
  });

  macTest('bubble width', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer(width: 400));
    var g = await press(tester);
    expect(tester.getSize(find.byKey(const Key('voice-bubble'))).width, 368);
    await g.up();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(layer(width: 1000));
    g = await press(tester);
    expect(tester.getSize(find.byKey(const Key('voice-bubble'))).width, 480);
    await g.up();
    await tester.pump(const Duration(milliseconds: 200));
  });

  macTest('other buttons fade while holding', (tester) async {
    await view(tester);
    await goLive(tester);
    await tester.pumpWidget(layer());
    double opacity() => tester.widget<FadeTransition>(find.ancestor(of: open, matching: find.byType(FadeTransition)).first).opacity.value;
    expect(opacity(), 1);
    final g = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(opacity(), 0);
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(opacity(), 1);
  });
}
