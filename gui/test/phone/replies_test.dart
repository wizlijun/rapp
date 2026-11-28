import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/phone/form.dart';
import 'package:rapp/phone/phone_nav.dart';
import 'package:rapp/phone/phone_shell.dart';
import 'package:rapp/phone/replies.dart';
import 'package:rapp/phone/reply_model.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/main_window.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/unlock.dart';

import '../fakes.dart';
import '../ui/main_window_test.dart' show FakeFullscreen;

const _t = ReplyTarget('m1', 'term:pty:a');
const _id = 'term\nm1\nterm:pty:a';

void main() {
  late Directory tmp;
  late FakeTransport tr;
  late MainState s;
  late List<Map<String, Object?>> calls;
  late Object? fail;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('replies_test');
    calls = [];
    fail = null;
    tr = FakeTransport();
    tr.emit({'event': 'hosts', 'hosts': [{'id': 'm1', 'name': 'mini'}]});
    s = MainState(
        hub: HubClient(tr),
        data: DataDir(tmp.path),
        prefs: UiPrefs(),
        port: FakeSessionPort(),
        unlockStore: UnlockStore(supported: false, memory: false),
        termPort: FakeTermSessionPort());
  });
  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  void push(String state, int seq) => tr.emit({
        'event': 'terms',
        'id': 'm1',
        'path': 'lan',
        'terms': [
          {
            'id': 'term:pty:a',
            'name': 'a',
            'command': 'zsh',
            'activity': 1,
            'unread': false,
            'reply': true,
            'ps': {'state': state, 'seq': seq, 'kind': 'approve', 'msg': 'x'},
          }
        ],
        'hosts': [],
      });

  PhoneReplies make({Duration gap = const Duration(milliseconds: 400)}) => PhoneReplies(s, reviseGap: gap, send: (t, {seq, text, enter = false, keys = const []}) async {
        calls.add({'at': clock.now(), 'seq': seq, 'text': text, 'enter': enter, 'keys': keys});
        if (fail != null) throw fail!;
      });

  /// Runs [body] under fake time, with the hub showing a waiting question #4.
  void run(void Function(FakeAsync a, PhoneReplies r) body) {
    fakeAsync((a) {
      push('blocked', 4);
      a.flushMicrotasks();
      final r = make();
      body(a, r);
      r.dispose();
    });
  }

  test('sends seq and keys once', () {
    run((a, r) {
      r.keys(_id, _t, 4, ['1'], doneWord: '已允许');
      a.flushMicrotasks();
      expect(calls.length, 1);
      expect(calls.single['seq'], 4);
      expect(calls.single['keys'], ['1']);
      expect(r.outcomeOf(_id)!.word, '已允许');
      expect(r.outcomeOf(_id)!.pending, isTrue);
      a.elapse(const Duration(seconds: 1));
      expect(calls.length, 1);
    });
  });

  test('local seq check skips send', () {
    run((a, r) {
      push('blocked', 5);
      a.flushMicrotasks();
      r.keys(_id, _t, 4, ['1'], doneWord: '已允许');
      a.flushMicrotasks();
      expect(calls, isEmpty);
      expect(r.outcomeOf(_id)!.word, '它已经不在等这一问了');
      expect(r.outcomeOf(_id)!.failed, isTrue);
    });
  });

  test('leaves wait within settle is success', () {
    run((a, r) {
      r.keys(_id, _t, 4, ['1'], doneWord: '已允许');
      a.flushMicrotasks();
      a.elapse(const Duration(seconds: 1));
      push('working', 4);
      a.flushMicrotasks();
      expect(r.outcomeOf(_id), isNull);
      a.elapse(const Duration(seconds: 5));
      expect(r.outcomeOf(_id), isNull);
    });
  });

  test('stays waiting past settle shows go-look and never resends', () {
    run((a, r) {
      r.keys(_id, _t, 4, ['1'], doneWord: '已允许');
      a.flushMicrotasks();
      a.elapse(const Duration(seconds: 2));
      expect(r.outcomeOf(_id)!.pending, isTrue);
      a.elapse(const Duration(seconds: 2));
      expect(r.outcomeOf(_id)!.word, '没成功，进去看看');
      expect(r.outcomeOf(_id)!.failed, isTrue);
      expect(calls.length, 1);
    });
  });

  test('changed refusal shows not-waiting', () {
    run((a, r) {
      fail = HubException('changed');
      r.keys(_id, _t, 4, ['1'], doneWord: '已允许');
      a.flushMicrotasks();
      expect(r.outcomeOf(_id)!.word, '它已经不在等这一问了');
      fail = HubException('typed');
      r.keys('x', _t, 4, ['1'], doneWord: '已允许');
      a.flushMicrotasks();
      expect(r.outcomeOf('x')!.word, '它已经不在等这一问了');
    });
  });

  test('old-run refusal shows go-look', () {
    run((a, r) {
      fail = HubException('this window was opened by an older version and cannot take a reply');
      r.keys(_id, _t, 4, ['1'], doneWord: '已允许');
      a.flushMicrotasks();
      expect(r.outcomeOf(_id)!.word, '这个会话是升级前开的，进去看看');
    });
  });

  test('offline at release sends nothing', () {
    run((a, r) {
      unawaited(tr.die());
      a.flushMicrotasks();
      r.keys(_id, _t, 4, ['1'], doneWord: '已允许');
      a.flushMicrotasks();
      expect(calls, isEmpty);
      expect(r.outcomeOf(_id)!.word, '连不上 A，没发');
    });
  });

  test('hub error after send shows go-look and never resends', () {
    run((a, r) {
      fail = HubException('boom');
      r.keys(_id, _t, 4, ['1'], doneWord: '已允许');
      a.flushMicrotasks();
      a.elapse(const Duration(seconds: 5));
      expect(r.outcomeOf(_id)!.word, '没成功，进去看看');
      expect(calls.length, 1);
    });
  });

  test('revise sends key then text with enter', () {
    run((a, r) {
      r.revise(_id, _t, 4, ['3'], '改一下');
      a.flushMicrotasks();
      expect(calls.length, 1);
      a.elapse(const Duration(milliseconds: 500));
      expect(calls.length, 2);
      expect(calls[0]['keys'], ['3']);
      expect(calls[0]['seq'], 4);
      expect(calls[1]['text'], '改一下');
      expect(calls[1]['enter'], isTrue);
      expect(calls[1]['seq'], isNull);
      expect((calls[1]['at'] as DateTime).difference(calls[0]['at'] as DateTime), greaterThanOrEqualTo(const Duration(milliseconds: 400)));
    });
  });

  test('say records input history, keys do not', () {
    final got = <String>[];
    s.recorder.onSent = (key, text, at) => got.add('$key|$text');
    run((a, r) {
      r.keys(_id, _t, 4, ['1'], doneWord: '已允许');
      a.flushMicrotasks();
      expect(got, isEmpty);
      a.elapse(const Duration(seconds: 4));
      push('blocked', 5);
      a.flushMicrotasks();
      r.say('y', _t, '好的');
      a.flushMicrotasks();
      expect(calls.last['text'], '好的');
      expect(calls.last['enter'], isTrue);
      expect(calls.last['seq'], isNull);
      expect(got, ['m1/term:pty:a|好的']);
    });
  });

  test('a dead view with the device online still sends', () {
    final s2 = _ViewDown(
        hub: s.hub,
        data: DataDir(tmp.path),
        prefs: UiPrefs(),
        port: FakeSessionPort(),
        unlockStore: UnlockStore(supported: false, memory: false),
        termPort: FakeTermSessionPort());
    fakeAsync((a) {
      push('blocked', 4);
      a.flushMicrotasks();
      final r = PhoneReplies(s2, send: (t, {seq, text, enter = false, keys = const []}) async => calls.add({'k': keys}));
      r.keys(_id, _t, 4, ['1'], doneWord: '已允许');
      a.flushMicrotasks();
      expect(calls.length, 1);
      r.dispose();
    });
  });

  group('form switch', () {
    testWidgets('outcome survives a form switch', (tester) async {
      tester.view.physicalSize = const Size(1194, 834);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final nav = PhoneNav(s, send: (t, {seq, text, enter = false, keys = const []}) async {});
      addTearDown(nav.dispose);
      push('blocked', 4);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      final r = nav.replies;
      await tester.pumpWidget(MaterialApp(
        theme: themeDataFor(RappTheme.matrix),
        home: phoneFormSwitch(
          state: s,
          nav: nav,
          data: DataDir(tmp.path),
          pad: (_) => MainWindow(state: s, monitor: null, control: null, fullscreen: FakeFullscreen()),
        ),
      ));
      await tester.pump();
      unawaited(r.keys(_id, _t, 4, ['1'], doneWord: '已允许'));
      await tester.pump();
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      await tester.pump(phoneFormSettle + const Duration(milliseconds: 10));
      expect(r.outcomeOf(_id)!.word, '已允许');
      tester.view.physicalSize = const Size(1194, 834);
      await tester.pump();
      await tester.pump(phoneFormSettle + const Duration(milliseconds: 10));
      expect(r.outcomeOf(_id)!.word, '已允许');
      await tester.pump(replySettle);
      expect(r.outcomeOf(_id)!.word, '没成功，进去看看');
    });
  });
}

/// A state whose view of every terminal is dropped while the device is online.
class _ViewDown extends MainState {
  _ViewDown({super.hub, required super.data, required super.prefs, required super.port, required super.unlockStore, required super.termPort});
  @override
  String? offlineWord(String device, String termId) => '已断开';
}
