import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
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

  test('PhoneNav.enter puts a pending draft into the session and opens it', () async {
    tmp = Directory.systemTemp.createTempSync('phone_voice_nav');
    final t2 = FakeTransport();
    t2.emit({'event': 'hosts', 'hosts': [{'id': 'm1', 'name': 'mini'}]});
    await Future<void>.delayed(Duration.zero);
    s = MainState(hub: HubClient(t2), data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort());
    replies = PhoneReplies(s);
    final nav = PhoneNav(s);
    nav.pendingDraft = '字';
    nav.enter('m1/none'); // no such session: nothing to put it in, and it is dropped
    expect(nav.pendingDraft, isNull);
    nav.dispose();
  });
}
