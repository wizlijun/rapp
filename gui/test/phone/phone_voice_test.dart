import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/embed/voice_button.dart' show voiceBlank;
import 'package:rapp/phone/home_screen.dart';
import 'package:rapp/state/state_sync.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/phone/phone_nav.dart';
import 'package:rapp/phone/phone_voice.dart';
import 'package:rapp/phone/replies.dart';
import 'package:rapp/phone/reply_model.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/unlock.dart';

import '../embed/voice_button_test.dart' show FakeVoice;
import '../fakes.dart';

class _Sync extends FakeStateSync {
  _Sync(super.localDir);
  final handled = <String>[];
  @override
  Future<void> markHandled(String eid) async => handled.add(eid);
}

const _t = ReplyTarget('m1', 'term:pty:a');
const _id = 'term\nm1\nterm:pty:a';

void main() {
  late Directory tmp;
  late FakeTransport tr;
  late FakeVoice voice;
  late MainState s;
  late PhoneReplies replies;
  late List<Map<String, Object?>> sent;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('phone_voice_test');
    sent = [];
    tr = FakeTransport();
    tr.emit({'event': 'hosts', 'hosts': [{'id': 'm1', 'name': 'mini'}]});
  });
  tearDown(() {
    replies.dispose();
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> boot(WidgetTester tester, {bool withVoice = true, Widget Function(Widget)? wrap}) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    voice = FakeVoice();
    s = MainState(
        hub: HubClient(tr),
        data: DataDir(tmp.path),
        prefs: UiPrefs(),
        port: FakeSessionPort(),
        voice: withVoice ? voice : null,
        unlockStore: UnlockStore(supported: false, memory: false),
        termPort: FakeTermSessionPort());
    replies = PhoneReplies(s, settle: const Duration(milliseconds: 50), send: (t, {seq, text, enter = false, keys = const []}) async {
      sent.add({'seq': seq, 'text': text, 'enter': enter, 'keys': keys});
    });
    tr.emit({
      'event': 'terms', 'id': 'm1', 'path': 'lan', 'hosts': [],
      'terms': [
        {
          'id': 'term:pty:a', 'name': 'a', 'command': 'zsh', 'activity': 1, 'unread': false, 'reply': true,
          'ps': {'state': 'blocked', 'seq': 4, 'kind': 'approve', 'msg': 'x'},
        }
      ],
    });
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }

  Widget host(Widget child) => MaterialApp(
        theme: themeDataFor(RappTheme.matrix),
        home: Scaffold(body: Center(child: SizedBox(width: 300, child: child))),
      );

  Widget voiceOf(MainState st, {required VoiceSend send, void Function(String)? edit, String label = '说一句'}) => PhoneVoice(
        state: st,
        key2: 'k1',
        send: send,
        edit: edit ?? (_) {},
        builder: (context, hold) => phoneVoiceButton(hold, label),
      );

  final button = find.byKey(const Key('phone-voice'));

  Future<void> say(WidgetTester tester, String words) async {
    voice.stopResult = words;
    final g = await tester.startGesture(tester.getCenter(button));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('say sends text with enter via replies', (tester) async {
    await boot(tester);
    await tester.pumpWidget(host(voiceOf(s, send: (text, v) {
      replies.say(_id, _t, text);
      return null;
    })));
    await say(tester, '再加一个测试');
    expect(sent, [
      {'seq': null, 'text': '再加一个测试', 'enter': true, 'keys': <String>[]}
    ]);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a hold with nothing heard sends nothing and says 没听清', (tester) async {
    await boot(tester);
    await tester.pumpWidget(host(voiceOf(s, send: (text, v) {
      replies.say(_id, _t, text);
      return null;
    })));
    await say(tester, '');
    expect(sent, isEmpty);
    expect(find.text(voiceBlank), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('replies refuse blank text and report whether they sent', (tester) async {
    await boot(tester);
    expect(await replies.say(_id, _t, '  '), isFalse);
    expect(await replies.revise(_id, _t, 4, ['3'], ''), isFalse);
    expect(sent, isEmpty);
    expect(await replies.keys(_id, _t, 4, ['1'], doneWord: '已允许'), isTrue);
    // A second action while the first is still watched is not sent, and says so.
    expect(await replies.keys(_id, _t, 4, ['1'], doneWord: '已允许'), isFalse);
    expect(sent.length, 1);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('revise sends the edit key with seq, then the words', (tester) async {
    await boot(tester);
    await tester.pumpWidget(host(voiceOf(label: '要改', s, send: (text, v) {
      replies.revise(_id, _t, 4, ['e'], text);
      return null;
    })));
    await say(tester, '把第二条删掉');
    await tester.pump(const Duration(seconds: 1));
    expect(sent.first, {'seq': 4, 'text': null, 'enter': false, 'keys': ['e']});
    expect(sent.last['text'], '把第二条删掉');
    expect(sent.last['enter'], true);
  });

  testWidgets('edit hands the words over, sends nothing', (tester) async {
    await boot(tester);
    String? got;
    await tester.pumpWidget(host(voiceOf(s, send: (t, v) => null, edit: (t) => got = t)));
    // The tidy card's 编辑 comes through voiceEdits, the same hand-over as the hold's own.
    s.voiceEdits['k1']!('改一改', null);
    expect(got, '改一改');
    expect(sent, isEmpty);
  });

  testWidgets('no recognizer hides voice buttons', (tester) async {
    await boot(tester, withVoice: false);
    await tester.pumpWidget(host(voiceOf(s, send: (t, v) => null)));
    expect(button, findsNothing);
    expect(s.voiceSends, isEmpty);
  });

  testWidgets('voice button is 64 high; dispose takes the key away', (tester) async {
    await boot(tester);
    await tester.pumpWidget(host(voiceOf(s, send: (t, v) => null)));
    expect(tester.getSize(button).height, greaterThanOrEqualTo(64));
    expect(s.voiceSends.containsKey('k1'), isTrue);
    await tester.pumpWidget(host(const SizedBox()));
    expect(s.voiceSends, isEmpty);
  });

  test('PhoneNav.enter drops a pending draft that is not for that session', () async {
    tmp = Directory.systemTemp.createTempSync('phone_voice_nav');
    final t2 = FakeTransport();
    t2.emit({'event': 'hosts', 'hosts': [{'id': 'm1', 'name': 'mini'}]});
    await Future<void>.delayed(Duration.zero);
    s = MainState(hub: HubClient(t2), data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort());
    replies = PhoneReplies(s);
    final nav = PhoneNav(s);
    nav.pendingDraft = (key: 'm1/other', text: '字');
    nav.enter('m1/none'); // no such session: nothing to put it in, and it is dropped
    expect(nav.pendingDraft, isNull);
    nav.dispose();
  });

  group('on the home screen', () {
    late PhoneNav nav;
    late _Sync sync;
    late bool failKeys;
    late List<Map<String, Object?>> homeSent;
    var sid = 0;

    Future<void> flush(WidgetTester tester) => tester.runAsync(() => Future<void>.delayed(Duration.zero));

    Future<void> bootHome(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await flush(tester);
      voice = FakeVoice();
      failKeys = false;
      homeSent = [];
      sid = 0;
      sync = _Sync(tmp.path)..status = StateStatus.connected;
      s = MainState(
          hub: HubClient(tr),
          data: DataDir(tmp.path),
          prefs: UiPrefs(),
          port: FakeSessionPort(),
          voice: voice,
          stateSync: sync,
          unlockStore: UnlockStore(supported: false, memory: false),
          termPort: FakeTermSessionPort());
      s.probes['m1'] = DeviceProbe(Lamp.active, '在线', apps: const AppList('m1', 'lan', [], capabilities: {'reply': true}));
      nav = PhoneNav(s, send: (t, {seq, text, enter = false, keys = const []}) async {
        homeSent.add({'seq': seq, 'text': text, 'enter': enter, 'keys': keys});
        if (failKeys && keys.isNotEmpty) throw Exception('x');
      });
      replies = nav.replies;
      tr.onSend = (m) {
        if (m['cmd'] == 'open') {
          tr.emit({'event': 'opened', 'sid': ++sid, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'req': m['req'], if (m['embed'] == true) ...{'port': 5000 + sid, 'token': 'tk'}});
        }
      };
      tr.emit({
        'event': 'terms', 'id': 'm1', 'path': 'lan', 'hosts': [],
        'terms': [
          {
            'id': 'term:pty:a', 'name': 'a', 'command': 'zsh', 'activity': 1, 'unread': false, 'reply': true,
            'fg': 'claude',
            'ps': {'state': 'blocked', 'seq': 4, 'kind': 'permission', 'msg': 'approve plan', 'app': 'claude-code', 'since': 10},
          }
        ],
      });
      sync.rows = [
        {'t': 'emit', 'level': 'info', 'id': 'm1', 'key': 'plan:term:pty:a', 'session': 'term:pty:a', 'text': '- 甲\n- 乙', 'at': 12, 'eid': 'e1'},
      ];
      await flush(tester);
      await tester.pumpWidget(MaterialApp(
        theme: themeDataFor(RappTheme.matrix),
        home: Scaffold(body: HomeScreen(state: s, nav: nav)),
      ));
      sync.push();
      await tester.pump();
    }

    testWidgets('要改 → 编辑 sends the edit key with the seq, then opens the session with the draft', (tester) async {
      await bootHome(tester);
      expect(find.byKey(const Key('phone-voice')), findsOneWidget);
      // Sign the session in first, so that the way in is open at once.
      await tester.runAsync(() async {
        s.openOrSwitch('m1', 'term:pty:a', 'a');
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      });
      s.voiceEdits.values.single('把第二条删了', null);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(homeSent.first, {'seq': 4, 'text': null, 'enter': false, 'keys': ['3']});
      expect(nav.now, PhoneView.session);
      expect(s.currentRemote?.composer.draft, '把第二条删了');
      expect(s.currentRemote?.composer.open, isTrue);
      expect(sync.handled, contains('e1'));
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('要改 → 编辑 whose keys fail stays out of the session and marks nothing', (tester) async {
      await bootHome(tester);
      failKeys = true;
      s.voiceEdits.values.single('字', null);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(nav.now, PhoneView.home);
      expect(nav.pendingDraft, isNull);
      expect(sync.handled, isEmpty);
      expect(nav.replies.outcomeOf(_id)?.failed, isTrue);
    });

    testWidgets('a second action while the first is pending marks nothing and does not go in', (tester) async {
      await bootHome(tester);
      await nav.replies.keys(_id, _t, 4, ['1'], doneWord: '已允许');
      s.voiceEdits.values.single('字', null);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(homeSent.length, 1);
      expect(nav.pendingDraft, isNull);
      expect(nav.now, PhoneView.home);
      expect(sync.handled, isEmpty);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a draft for session A leaves session B untouched', (tester) async {
      await bootHome(tester);
      await tester.runAsync(() async {
        s.openOrSwitch('m1', 'term:pty:b', 'b');
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      });
      nav.pendingDraft = (key: 'm1/term:pty:a', text: '给 A 的');
      nav.enter('m1/term:pty:b');
      expect(s.currentRemote?.composer.draft ?? '', '');
      expect(nav.pendingDraft, isNull);
    });
  });
}
