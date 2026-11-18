import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/picture.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/voice_key_gate.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/side_panel.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late MainState s;
  late FakeSessionPort port;
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('side_panel_voice');
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
    port = FakeSessionPort();
    s = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester, TargetPlatform p) async {
    debugDefaultTargetPlatformOverride = p;
    await tester.pumpWidget(wrap(SidePanel(state: s, devicesTab: const Text('d'))));
  }

  // The binding checks its debug variables before tearDown runs, so the override is reset here.
  void voiceTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
        try {
          await body(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

  Map<String, Object?> lastSet() => port.calls.lastWhere((c) => c.$1 == 'set_voice_hotkey').$2;

  voiceTest('shows the default', (tester) async {
    await mount(tester, TargetPlatform.macOS);
    expect(find.byKey(const Key('voice-hotkey')), findsOneWidget);
    expect(find.text('语音快捷键'), findsOneWidget);
    expect(find.text('长按 右 ⌥'), findsOneWidget);
  });

  voiceTest('Linux has no row', (tester) async {
    await mount(tester, TargetPlatform.linux);
    expect(find.byKey(const Key('voice-hotkey')), findsNothing);
  });

  voiceTest('record ⌃⌥Space', (tester) async {
    await mount(tester, TargetPlatform.macOS);
    await tester.tap(find.byKey(const Key('voice-hotkey-change')));
    await tester.pump();
    expect(find.text('请按下快捷键…（Esc 取消）'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text('按住 ⌃⌥Space'), findsOneWidget);
    expect(lastSet(), {'hotkey': {'kind': 'hold_combo', 'key_code': 49, 'modifiers': 786432}});
    final j = jsonDecode(File('${s.data.prefsDir()}/gui.json').readAsStringSync()) as Map;
    expect(j['voice_hotkey'], {'kind': 'hold_combo', 'key_code': 49, 'modifiers': 786432});
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  voiceTest('a plain key is refused and recording goes on', (tester) async {
    await mount(tester, TargetPlatform.macOS);
    await tester.tap(find.byKey(const Key('voice-hotkey-change')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(find.text('这个键不能用'), findsOneWidget);
    expect(find.textContaining('请按下快捷键…'), findsOneWidget);
    expect(s.prefs.voiceHotkey, VoiceHotkey.standard);
  });

  voiceTest('Esc leaves recording unchanged', (tester) async {
    await mount(tester, TargetPlatform.macOS);
    await tester.tap(find.byKey(const Key('voice-hotkey-change')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.textContaining('请按下快捷键…'), findsNothing);
    expect(find.text('长按 右 ⌥'), findsOneWidget);
    expect(s.prefs.voiceHotkey, VoiceHotkey.standard);
  });

  voiceTest('关 and 恢复默认', (tester) async {
    await mount(tester, TargetPlatform.macOS);
    await tester.tap(find.byKey(const Key('voice-hotkey-off')));
    await tester.pump();
    expect(find.text('关'), findsWidgets);
    expect(lastSet(), {'hotkey': 'off'});
    await tester.tap(find.byKey(const Key('voice-hotkey-default')));
    await tester.pump();
    expect(find.text('长按 右 ⌥'), findsOneWidget);
    expect(lastSet(), {'hotkey': {'kind': 'hold_modifier', 'key_code': 61}});
  });

  voiceTest('each 改 starts a fresh recorder', (tester) async {
    await mount(tester, TargetPlatform.macOS);
    // First recording ends on ⌃⌥Space; the keys come up after recording is over, so a reused
    // recorder would still think ⌃ and ⌥ are held.
    await tester.tap(find.byKey(const Key('voice-hotkey-change')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text('按住 ⌃⌥Space'), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    // Second recording: the first key is judged on its own, a lone Left Option hold.
    await tester.tap(find.byKey(const Key('voice-hotkey-change')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(find.text('长按 左 ⌥'), findsOneWidget);
    expect(lastSet(), {'hotkey': {'kind': 'hold_modifier', 'key_code': 58}});
  });

  voiceTest('losing focus ends recording', (tester) async {
    await mount(tester, TargetPlatform.macOS);
    await tester.tap(find.byKey(const Key('voice-hotkey-change')));
    await tester.pump();
    expect(find.text('请按下快捷键…（Esc 取消）'), findsOneWidget);
    expect(s.voiceHotkeyRecording, isTrue);
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pump();
    expect(find.text('请按下快捷键…（Esc 取消）'), findsNothing);
    expect(find.text('长按 右 ⌥'), findsOneWidget);
    expect(s.voiceHotkeyRecording, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(find.text('这个键不能用'), findsNothing);
    expect(s.prefs.voiceHotkey, VoiceHotkey.standard);
  });

  voiceTest('the picture does not take the keys back while recording', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final tr = FakeTransport();
    final hub = HubClient(tr);
    tr.emit({'event': 'hosts', 'hosts': [{'id': '111', 'name': 'mini'}]});
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    s.dispose();
    s = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
    await tester.runAsync(() async {
      tr.onSend = (m) {
        if (m['cmd'] == 'open') {
          tr.emit({'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
            'port': 5001, 'token': 'tk', 'req': m['req']});
        }
      };
      s.openOrSwitch('111', 'Safari', 'Safari');
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    final rs = s.currentRemote!;
    final w = RemoteWindow(
      id: 5, parent: 0, kind: WindowKind.normal, title: 'w', rect: const Rect.fromLTWH(0, 0, 400, 328),
      titleBar: 28, resizable: true, focused: true, texture: 42, visible: const Rect.fromLTWH(0, 0, 1, 1),
    );
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(SizedBox(
      width: 800,
      height: 800,
      child: Row(children: [
        SizedBox(width: 400, height: 328, child: Picture(state: s, session: rs, window: w)),
        Expanded(child: SidePanel(state: s, devicesTab: const Text('d'))),
      ]),
    )));
    await tester.pump();
    await tester.pump();
    expect(s.pictureFocused, 1); // the picture settles onto A by itself
    await tester.tap(find.byKey(const Key('voice-hotkey-change')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(s.pictureFocused, isNull);
    final focuses = [for (final c in port.calls) if (c.$1 == 'picture_focus') c.$2['sid']];
    expect(focuses.last, isNull);
    // The row gets the keys.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text('按住 ⌃⌥Space'), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 300));
    expect(s.voiceHotkeyRecording, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
