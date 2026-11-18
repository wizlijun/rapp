import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
