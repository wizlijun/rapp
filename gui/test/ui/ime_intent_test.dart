import 'dart:async';

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/local_ime.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/ime_intent.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';

/// Records every call; [now] is what `current` answers, [hang] makes `toChinese` never return.
class _FakeIme implements LocalIme {
  final calls = <String>[];
  ({String id, bool ascii})? now;
  bool hang = false;

  @override
  Future<String?> toChinese(String? preferredId) {
    calls.add('toChinese:$preferredId');
    if (hang) return Completer<String?>().future;
    return Future.value(preferredId ?? 'picked');
  }

  @override
  Future<void> toEnglish() async => calls.add('toEnglish');

  @override
  Future<({String id, bool ascii})?> current() async {
    calls.add('current');
    return now;
  }
}

void main() {
  // MainState listens for the app coming back (AppLifecycleListener) when it has a local input method.
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeIme ime;
  late bool enabled, secure;
  late String? last;
  late List<String> saved;

  setUp(() {
    ime = _FakeIme();
    enabled = true;
    secure = false;
    last = 'im.rime';
    saved = [];
  });

  ImeIntent make() =>
      ImeIntent(ime, enabled: () => enabled, secure: () => secure, lastId: () => last, saveId: (id) => saved.add(id));

  test('enter switches to Chinese with the saved id', () {
    fakeAsync((a) {
      final intent = make();
      intent.focus(1, true);
      a.flushTimers();
      expect(ime.calls, ['toChinese:im.rime']);
    });
  });

  test('leave saves a non-ASCII source then goes English', () {
    fakeAsync((a) {
      final intent = make();
      intent.focus(1, true);
      a.flushTimers();
      ime.calls.clear();
      ime.now = (id: 'sogou', ascii: false);
      intent.focus(1, false);
      a.flushTimers();
      expect(saved, ['sogou']);
      expect(ime.calls, ['current', 'toEnglish']);
    });
  });

  test('leave from an ASCII source saves nothing', () {
    fakeAsync((a) {
      final intent = make();
      intent.focus(1, true);
      a.flushTimers();
      ime.calls.clear();
      ime.now = (id: 'com.apple.keylayout.ABC', ascii: true);
      intent.focus(1, false);
      a.flushTimers();
      expect(saved, isEmpty);
      expect(ime.calls, ['current', 'toEnglish']);
    });
  });

  test('only edges', () {
    fakeAsync((a) {
      final intent = make();
      intent.focus(1, true);
      a.flushTimers();
      intent.focus(1, true);
      a.flushTimers();
      expect(ime.calls, ['toChinese:im.rime']);
    });
  });

  test('swap between two editors switches once', () {
    fakeAsync((a) {
      final intent = make();
      intent.focus(1, true);
      a.flushTimers();
      ime.calls.clear();
      intent.focus(1, false);
      intent.focus(2, true);
      a.flushTimers();
      expect(ime.calls, isEmpty);
    });
    fakeAsync((a) {
      final fresh = _FakeIme();
      final i2 = ImeIntent(fresh, enabled: () => true, secure: () => false, lastId: () => null, saveId: (_) {});
      i2.focus(2, true);
      a.flushTimers();
      expect(fresh.calls, ['toChinese:null']);
    });
  });

  test('the id saved on a leave is the one the next enter asks for', () {
    fakeAsync((a) {
      final intent = ImeIntent(ime, enabled: () => true, secure: () => false, lastId: () => last, saveId: (id) => last = id);
      intent.focus(1, true);
      a.flushTimers();
      ime.now = (id: 'sogou', ascii: false);
      intent.focus(1, false);
      a.flushTimers();
      intent.focus(1, true);
      a.flushTimers();
      expect(ime.calls, ['toChinese:im.rime', 'current', 'toEnglish', 'toChinese:sogou']);
    });
  });

  test('switch off does nothing', () {
    fakeAsync((a) {
      enabled = false;
      final intent = make();
      intent.focus(1, true);
      a.flushTimers();
      intent.focus(1, false);
      a.flushTimers();
      intent.appResumed();
      a.flushTimers();
      expect(ime.calls, isEmpty);
    });
  });

  test('password field does nothing', () {
    fakeAsync((a) {
      secure = true;
      final intent = make();
      intent.focus(1, true);
      a.flushTimers();
      intent.focus(1, false);
      a.flushTimers();
      expect(ime.calls, isEmpty);
      expect(saved, isEmpty);
    });
  });

  test('app resumed with caret inside switches again', () {
    fakeAsync((a) {
      final intent = make();
      intent.focus(1, true);
      a.flushTimers();
      intent.appResumed();
      a.flushTimers();
      expect(ime.calls, ['toChinese:im.rime', 'toChinese:im.rime']);
    });
  });

  test('app resumed with the caret outside does nothing', () {
    fakeAsync((a) {
      final intent = make();
      intent.appResumed();
      a.flushTimers();
      intent.focus(1, true);
      a.flushTimers();
      intent.focus(1, false);
      a.flushTimers();
      ime.calls.clear();
      intent.appResumed();
      a.flushTimers();
      expect(ime.calls, isEmpty);
    });
  });

  test('hung toChinese still settles', () {
    fakeAsync((a) {
      ime.hang = true;
      final intent = make();
      intent.focus(1, true);
      var done = false;
      intent.settled.then((_) => done = true);
      a.elapse(const Duration(milliseconds: 299));
      expect(done, isFalse);
      a.elapse(const Duration(milliseconds: 1));
      expect(done, isTrue);
      // The chain goes on after the timeout: a leave still runs.
      intent.focus(1, false);
      a.flushTimers();
      expect(ime.calls, ['toChinese:im.rime', 'current', 'toEnglish']);
    });
  });

  test('settled waits for a queued settle and for the calls', () {
    fakeAsync((a) {
      var done = false;
      final intent = make();
      intent.focus(1, true);
      intent.settled.then((_) => done = true);
      expect(ime.calls, isEmpty);
      a.flushMicrotasks();
      expect(done, isFalse);
      a.flushTimers();
      expect(done, isTrue);
      expect(ime.calls, ['toChinese:im.rime']);
    });
  });

  test('errors are caught', () {
    fakeAsync((a) {
      final bad = _ThrowingIme();
      final i = ImeIntent(bad, enabled: () => true, secure: () => false, lastId: () => null, saveId: (_) {});
      i.focus(1, true);
      a.flushTimers();
      i.focus(1, false);
      var done = false;
      i.settled.then((_) => done = true);
      a.flushTimers();
      expect(done, isTrue);
      expect(bad.calls, ['toChinese', 'current', 'toEnglish']);
    });
  });

  group('an enter that keeps the input method (Linux: the opening letter went in as text)', () {
    test('no switch for that enter; the leave still goes English', () {
      fakeAsync((a) {
        final intent = make();
        intent.focus(1, true, keepIme: true);
        a.flushTimers();
        expect(ime.calls, isEmpty);
        ime.now = (id: 'fcitx5', ascii: false);
        intent.focus(1, false);
        a.flushTimers();
        expect(ime.calls, ['current', 'toEnglish']);
        expect(saved, ['fcitx5']);
      });
    });

    test('only that enter: the next one switches', () {
      fakeAsync((a) {
        final intent = make();
        intent.focus(1, true, keepIme: true);
        a.flushTimers();
        intent.focus(1, false);
        a.flushTimers();
        ime.calls.clear();
        intent.focus(1, true);
        a.flushTimers();
        expect(ime.calls, ['toChinese:im.rime']);
      });
    });
  });

  group('a leave waits a grace', () {
    test('an enter several turns and ~100 ms after the leave: no native calls', () {
      fakeAsync((a) {
        final intent = make();
        intent.focus(1, true);
        a.flushTimers();
        ime.calls.clear();
        intent.focus(1, false); // the old panel unmounts
        a.flushMicrotasks();
        a.elapse(Duration.zero);
        a.elapse(const Duration(milliseconds: 50));
        a.flushMicrotasks();
        a.elapse(const Duration(milliseconds: 50));
        intent.focus(2, true); // the new one gets the caret after its native focus round trip
        a.flushTimers();
        expect(ime.calls, isEmpty);
        expect(saved, isEmpty);
      });
    });

    test('an enter at 250 ms: leave then enter, as before', () {
      fakeAsync((a) {
        final intent = make();
        intent.focus(1, true);
        a.flushTimers();
        ime.calls.clear();
        ime.now = (id: 'sogou', ascii: false);
        intent.focus(1, false);
        a.elapse(const Duration(milliseconds: 199));
        expect(ime.calls, isEmpty);
        a.elapse(const Duration(milliseconds: 51));
        expect(ime.calls, ['current', 'toEnglish']);
        intent.focus(2, true);
        a.flushTimers();
        expect(ime.calls, ['current', 'toEnglish', 'toChinese:im.rime']);
      });
    });

    test('settled does not wait out the grace', () {
      fakeAsync((a) {
        final intent = make();
        intent.focus(1, true);
        a.flushTimers();
        intent.focus(1, false);
        var done = false;
        intent.settled.then((_) => done = true);
        a.elapse(Duration.zero);
        expect(done, isTrue);
        expect(ime.calls, ['toChinese:im.rime']);
        a.flushTimers();
        expect(ime.calls, ['toChinese:im.rime', 'current', 'toEnglish']);
      });
    });

    test('dispose drops a pending leave', () {
      fakeAsync((a) {
        final intent = make();
        intent.focus(1, true);
        a.flushTimers();
        intent.focus(1, false);
        a.elapse(Duration.zero);
        intent.dispose();
        expect(a.pendingTimers, isEmpty);
        expect(ime.calls, ['toChinese:im.rime']);
      });
    });
  });

  group('while the app is not in front', () {
    test('inactive then the caret leaving: no calls', () {
      fakeAsync((a) {
        final intent = make();
        intent.focus(1, true);
        a.flushTimers();
        ime.calls.clear();
        intent.appInactive();
        intent.focus(1, false); // the window lost focus and so did the text field
        a.flushTimers();
        expect(ime.calls, isEmpty);
      });
    });

    test('inactive cancels a leave already waiting its grace', () {
      fakeAsync((a) {
        final intent = make();
        intent.focus(1, true);
        a.flushTimers();
        ime.calls.clear();
        intent.focus(1, false);
        a.elapse(const Duration(milliseconds: 100));
        intent.appInactive();
        a.flushTimers();
        expect(ime.calls, isEmpty);
      });
    });

    test('resume with the caret restored before appResumed: one toChinese', () {
      fakeAsync((a) {
        final intent = make();
        intent.focus(1, true);
        a.flushTimers();
        ime.calls.clear();
        intent.appInactive();
        intent.focus(1, false);
        a.flushTimers();
        intent.focus(1, true);
        intent.appResumed();
        a.flushTimers();
        expect(ime.calls, ['toChinese:im.rime']);
      });
    });

    test('resume with the caret restored after appResumed: one toChinese', () {
      fakeAsync((a) {
        final intent = make();
        intent.focus(1, true);
        a.flushTimers();
        ime.calls.clear();
        intent.appInactive();
        intent.focus(1, false);
        a.flushTimers();
        intent.appResumed();
        a.flushMicrotasks();
        intent.focus(1, true);
        a.flushTimers();
        expect(ime.calls, ['toChinese:im.rime']);
      });
    });

    test('resume with the caret restored a turn after appResumed: one toChinese', () {
      fakeAsync((a) {
        final intent = make();
        intent.focus(1, true);
        a.flushTimers();
        ime.calls.clear();
        intent.appInactive();
        intent.focus(1, false);
        a.flushTimers();
        intent.appResumed();
        a.flushTimers();
        intent.focus(1, true);
        a.flushTimers();
        expect(ime.calls, ['toChinese:im.rime']);
      });
    });

    test('inactive with the caret inside, resumed with it still inside: one toChinese', () {
      fakeAsync((a) {
        final intent = make();
        intent.focus(1, true);
        a.flushTimers();
        ime.calls.clear();
        intent.appInactive();
        a.flushTimers();
        intent.appResumed();
        a.flushTimers();
        expect(ime.calls, ['toChinese:im.rime']);
      });
    });

    test('resumed with the caret outside: nothing, and the next enter switches', () {
      fakeAsync((a) {
        final intent = make();
        intent.focus(1, true);
        a.flushTimers();
        ime.calls.clear();
        intent.appInactive();
        intent.focus(1, false);
        a.flushTimers();
        intent.appResumed();
        a.flushTimers();
        expect(ime.calls, isEmpty);
        intent.focus(1, true);
        a.flushTimers();
        expect(ime.calls, ['toChinese:im.rime']);
      });
    });

    test('an enter while inactive does not switch until resumed', () {
      fakeAsync((a) {
        final intent = make();
        intent.appInactive();
        intent.focus(1, true);
        a.flushTimers();
        expect(ime.calls, isEmpty);
        intent.appResumed();
        a.flushTimers();
        expect(ime.calls, ['toChinese:im.rime']);
      });
    });
  });

  group('MainState wiring', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('ime_intent_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    void env(void Function(FakeAsync a, MainState st) body) {
      fakeAsync((a) {
        final t = FakeTransport();
        final st = MainState(
            hub: HubClient(t), data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort(), localIme: ime);
        t.onSend = (m) {
          if (m['cmd'] == 'open') {
            t.emit({'event': 'opened', 'sid': 7, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'port': 5007,
                'token': 'tk', 'req': m['req']});
          }
        };
        t.emit({'event': 'hosts', 'hosts': [{'id': '111', 'name': 'mini'}]});
        a.flushMicrotasks();
        st.openOrSwitch('111', 'a', 'Calculator');
        a.flushMicrotasks();
        body(a, st);
        st.dispose();
      });
    }

    test('the writing panel taking and losing the caret switches, and the switch is followed', () {
      env((a, st) {
        final rs = st.currentRemote!;
        st.composerFocusChanged(rs, true);
        var settled = false;
        st.imeSettled.then((_) => settled = true);
        a.flushMicrotasks();
        expect(settled, isFalse); // the switch is still queued
        a.flushTimers();
        expect(settled, isTrue);
        expect(ime.calls, ['toChinese:null']);
        ime.now = (id: 'sogou', ascii: false);
        st.composerFocusChanged(rs, false);
        a.flushTimers();
        expect(ime.calls, ['toChinese:null', 'current', 'toEnglish']);
        expect(st.prefs.chineseIme, 'sogou');
        st.setImeIntent(false);
        expect(st.prefs.imeIntent, isFalse);
        st.composerFocusChanged(rs, true);
        a.flushTimers();
        expect(ime.calls.length, 3);
      });
    });

    test('the app going inactive stops switching until it is back', () {
      env((a, st) {
        final rs = st.currentRemote!;
        st.composerFocusChanged(rs, true);
        a.flushTimers();
        ime.calls.clear();
        st.imeLifecycle(AppLifecycleState.inactive);
        st.composerFocusChanged(rs, false);
        a.flushTimers();
        expect(ime.calls, isEmpty);
        st.composerFocusChanged(rs, true);
        st.imeLifecycle(AppLifecycleState.resumed);
        a.flushTimers();
        expect(ime.calls, ['toChinese:null']);
      });
    });

    test('a panel opened by a Linux letter keeps the input method; a later caret switches', () {
      env((a, st) {
        final rs = st.currentRemote!;
        rs.apply(ComposerInsertEvent(rs.sid, const PasteResult(text: 'n'), letter: true));
        expect(rs.composer.keepImeOnFocus, isTrue);
        st.composerFocusChanged(rs, true);
        a.flushTimers();
        expect(ime.calls, isEmpty);
        expect(rs.composer.keepImeOnFocus, isFalse); // used up by that enter
        st.composerFocusChanged(rs, false);
        a.flushTimers();
        st.composerFocusChanged(rs, true);
        a.flushTimers();
        expect(ime.calls, ['current', 'toEnglish', 'toChinese:null']);
      });
    });

    test('a clip inserted (not a letter) still switches', () {
      env((a, st) {
        final rs = st.currentRemote!;
        rs.apply(ComposerInsertEvent(rs.sid, const PasteResult(text: 'clip')));
        st.composerFocusChanged(rs, true);
        a.flushTimers();
        expect(ime.calls, ['toChinese:null']);
      });
    });

    test('the editor going away while it had the caret leaves', () {
      env((a, st) {
        final rs = st.currentRemote!;
        final ed = FakeEditor();
        rs.composer.attach(ed);
        st.composerFocusChanged(rs, true);
        a.flushTimers();
        rs.composer.detach(ed);
        a.flushTimers();
        expect(ime.calls, ['toChinese:null', 'current', 'toEnglish']);
      });
    });
  });
}

class _ThrowingIme implements LocalIme {
  final calls = <String>[];
  @override
  Future<String?> toChinese(String? preferredId) async {
    calls.add('toChinese');
    throw StateError('no');
  }

  @override
  Future<void> toEnglish() {
    calls.add('toEnglish');
    throw StateError('sync no');
  }

  @override
  Future<({String id, bool ascii})?> current() async {
    calls.add('current');
    throw StateError('no');
  }
}
