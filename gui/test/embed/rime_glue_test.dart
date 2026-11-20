import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/rime_glue.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/app_profile_store.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp_rime/rapp_rime.dart';

import '../fakes.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rapp/rime-glue-test');
  late Directory tmp;
  late List<MethodCall> calls;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rime_glue_test');
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
    calls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    tmp.deleteSync(recursive: true);
  });

  const notes = 'com.apple.Notes', term = 'com.apple.Terminal';

  /// Two sessions (Notes, then Terminal, which ends up on the stage) and a glue on a fresh RappRime.
  void env(void Function(FakeAsync a, MainState st, RimeGlue glue, RappRime rime) body,
      {UiPrefs? prefs, List<AppProfile> mine = const []}) {
    fakeAsync((a) {
      final t = FakeTransport();
      final st = MainState(
        hub: HubClient(t),
        data: DataDir(tmp.path),
        prefs: prefs ?? UiPrefs(),
        port: FakeSessionPort(),
        profiles: AppProfileStore('${tmp.path}/shared', mine: [...mine]),
      );
      t.onSend = (m) {
        if (m['cmd'] == 'open') {
          final n = (m['app'] as String).length;
          t.emit({
            'event': 'opened', 'sid': n, 'id': m['id'], 'app': m['app'], 'path': 'lan',
            if (m['embed'] == true) ...{'port': 5000 + n, 'token': 'tk'},
            'req': m['req'],
          });
        }
      };
      a.flushMicrotasks();
      st.openOrSwitch('111', notes, 'Notes');
      a.flushMicrotasks();
      st.openOrSwitch('111', term, '终端');
      a.flushMicrotasks();
      final rime = RappRime(channel);
      final glue = RimeGlue(st, rime: rime);
      body(a, st, glue, rime);
      glue.dispose();
      rime.dispose();
      st.dispose();
    });
  }

  test('on by default, bundled; with the switch off, enabled is false', () {
    env((a, st, glue, rime) {
      expect(rime.enabled, isTrue);
      expect(rime.builtin, isTrue);
      st.setRimeEnabled(false);
      expect(rime.enabled, isFalse);
      expect(st.prefs.rimeEnabled, isFalse);
      st.setRimeEnabled(true);
      expect(rime.enabled, isTrue);
    });
    env((a, st, glue, rime) => expect(rime.enabled, isFalse), prefs: UiPrefs(rimeEnabled: false));
  });

  test('the dictionary follows the prefs', () {
    env((a, st, glue, rime) {
      a.flushMicrotasks();
      expect(calls.where((c) => c.method == 'configure').last.arguments, {'enabled': true, 'dictionary': 'bundled'});
      glue.setDictionary(RimeDictionary.user);
      a.flushMicrotasks();
      expect(st.prefs.rimeDictionary, 'user');
      expect(glue.dictionary, RimeDictionary.user);
      expect(calls.where((c) => c.method == 'configure').last.arguments, {'enabled': true, 'dictionary': 'user'});
    });
  });

  test('「内」/「系」 follows the session on the stage, from its app profile', () {
    env((a, st, glue, rime) {
      expect(st.currentRemote!.appId, term);
      expect(rime.builtin, isFalse);
      st.select('111/$notes');
      expect(st.currentRemote!.appId, notes);
      expect(rime.builtin, isTrue);
      st.select('111/$term');
      expect(rime.builtin, isFalse);
    }, mine: [AppProfile(ids: [term], rime: false)]);
  });

  test('a 「内」/「系」 tap writes the profile of the session on the stage only, and sticks', () {
    env((a, st, glue, rime) {
      expect(rime.builtin, isTrue);
      rime.toggleBuiltin(); // on Terminal
      expect(st.profiles.resolve(term).rime, isFalse);
      expect(st.profiles.resolve(notes).rime, isTrue);
      expect(st.profiles.mine.where((p) => p.matches(notes)), isEmpty);
      expect(rime.builtin, isFalse);
      st.select('111/$notes');
      expect(rime.builtin, isTrue, reason: 'another session is not affected');
      st.select('111/$term');
      expect(rime.builtin, isFalse);
      expect(AppProfileStore.load('${tmp.path}/shared', null).resolve(term).rime, isFalse, reason: 'saved');
    });
  });

  test('after dispose the glue no longer follows', () {
    env((a, st, glue, rime) {
      glue.dispose();
      st.setRimeEnabled(false);
      expect(rime.enabled, isTrue);
    });
  });
}
