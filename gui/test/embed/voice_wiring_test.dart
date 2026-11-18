import 'dart:io';
import 'dart:ui' show Rect;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/voice_key_gate.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('voice_wiring'));
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    tmp.deleteSync(recursive: true);
  });

  RemoteWindow rw(int id) => RemoteWindow(
        id: id,
        parent: 0,
        kind: WindowKind.normal,
        title: 'w$id',
        rect: const Rect.fromLTWH(0, 0, 400, 328),
        titleBar: 28,
        resizable: true,
        focused: false,
        texture: id,
        visible: const Rect.fromLTWH(0, 0, 1, 1),
      );

  void env(TargetPlatform platform, void Function(FakeAsync a, FakeSessionPort port, MainState st) body) {
    debugDefaultTargetPlatformOverride = platform;
    fakeAsync((a) {
      final t = FakeTransport();
      final hub = HubClient(t);
      final port = FakeSessionPort();
      final st = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
      t.onSend = (m) {
        if (m['cmd'] == 'open') {
          t.emit({
            'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan',
            if (m['embed'] == true) ...{'port': 5001, 'token': 'tk'},
            'req': m['req'],
          });
        }
      };
      a.flushMicrotasks();
      st.openOrSwitch('111', 'a', 'Calculator');
      a.flushMicrotasks();
      body(a, port, st);
      st.dispose();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  Map<String, Object?> lastFocus(FakeSessionPort port) =>
      port.calls.lastWhere((c) => c.$1 == 'picture_focus' && c.$2['sid'] == 1).$2;

  test('focusing an app picture tells native it may talk', () {
    env(TargetPlatform.macOS, (a, port, st) {
      port.emit(WindowsEvent(1, [rw(7)]));
      st.focusPicture(1);
      expect(lastFocus(port), {'sid': 1, 'compose': true, 'voice': true});
    });
  });

  test('an open panel takes voice away', () {
    env(TargetPlatform.macOS, (a, port, st) {
      port.emit(WindowsEvent(1, [rw(7)]));
      st.focusPicture(1);
      expect(lastFocus(port)['voice'], true);
      st.currentRemote!.composer.open = true;
      expect(st.pictureFocused, 1);
      expect(lastFocus(port).containsKey('voice'), false);
    });
  });

  test('linux enables local speech and sends the voice flag', () {
    env(TargetPlatform.linux, (a, port, st) {
      port.emit(WindowsEvent(1, [rw(7)]));
      st.focusPicture(1);
      expect(lastFocus(port)['voice'], true);
      expect(st.voice, isNotNull);
      expect(st.voice!.finalWait, const Duration(seconds: 90));
    });
  });

  test('hotkey sent at start and on change', () {
    env(TargetPlatform.macOS, (a, port, st) {
      expect(port.calls.where((c) => c.$1 == 'set_voice_hotkey').map((c) => c.$2).toList(), [
        {'hotkey': {'kind': 'hold_modifier', 'key_code': 61}},
      ]);
      st.setVoiceHotkey(VoiceHotkey.off);
      expect(port.calls.last.$1, 'set_voice_hotkey');
      expect(port.calls.last.$2, {'hotkey': 'off'});
      expect(st.prefs.voiceHotkey, VoiceHotkey.off);
    });
  });

  test('voice_key events reach voiceKeys', () {
    env(TargetPlatform.macOS, (a, port, st) {
      port.emit(WindowsEvent(1, [rw(7)]));
      final got = <(Object, VoiceKeyPhase)>[];
      st.voiceKeys.listen(got.add);
      port.emit(const VoiceKeyEvent(1, VoiceKeyPhase.start));
      a.flushMicrotasks();
      expect(got, [(1, VoiceKeyPhase.start)]);
    });
  });

  test('voiceEnd goes to the app port; language hint is remembered', () {
    env(TargetPlatform.macOS, (a, port, st) {
      st.voiceEnd(1);
      expect(port.calls.last.$1, 'voice_end');
      expect(port.calls.last.$2, {'sid': 1});
      st.voiceLanguageHintDone();
      expect(st.prefs.voiceLanguageHintShown, true);
    });
  });

  test('voice_key parses', () {
    final e = parseSessionEvent('voice_key', {'sid': 1, 'phase': 'edit'}) as VoiceKeyEvent;
    expect(e.sid, 1);
    expect(e.phase, VoiceKeyPhase.edit);
    expect(parseSessionEvent('voice_key', {'sid': 1, 'phase': 'x'}), isNull);
  });
}
