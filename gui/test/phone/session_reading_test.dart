import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/geometry.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/composer_model.dart' show VoiceOrigin;
import 'package:rapp/embed/voice_tidy_card.dart';
import 'package:rapp/embed/voice_ring.dart' show VoicePick;
import 'package:rapp/phone/phone_voice.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/llm_api.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/phone/home_screen.dart';
import 'package:rapp/phone/phone_nav.dart';
import 'package:rapp/phone/reading_view.dart';
import 'package:rapp/phone/reply_card.dart';
import 'package:rapp/phone/session_view.dart';
import 'package:rapp/state/state_sync.dart';
import 'package:rapp/term/term_stage.dart';
import 'package:rapp/term/term_wire.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/unlock.dart';

import '../embed/voice_button_test.dart' show FakeVoice;
import '../fakes.dart';

const _long = '这是一段比较长的中性测试文字';

class _Sync extends FakeStateSync {
  _Sync(super.localDir);
}

void main() {
  late Directory tmp;
  late FakeTransport t;
  late MainState s;
  late PhoneNav nav;
  late FakeSessionPort port;
  late FakeTermSessionPort term;
  late FakeVoice voice;
  late _Sync sync;
  late List<Map<String, Object?>> sent;
  var failSend = false;
  // Set: a send waits on it, so a test can land a push before the answer.
  Completer<void>? hang;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('session_reading_test');
  });
  tearDown(() {
    nav.dispose();
    s.dispose();
    term.dispose();
    tmp.deleteSync(recursive: true);
  });

  RemoteWindow win(int id, {int? texture}) => RemoteWindow(
        id: id,
        parent: 0,
        kind: WindowKind.normal,
        title: 'w$id',
        rect: const Rect.fromLTWH(0, 0, 400, 328),
        titleBar: 28,
        resizable: true,
        focused: true,
        texture: texture,
        visible: const Rect.fromLTWH(0, 0, 1, 1),
      );

  Future<void> boot(WidgetTester tester, {String app = 'term:pty:a', bool withVoice = true, bool card = false}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    t = FakeTransport();
    final hub = HubClient(t);
    t.emit({
      'event': 'hosts',
      'hosts': [
        {'id': 'm1', 'name': 'mini'},
      ],
    });
    await tester.runAsync(flush);
    port = FakeSessionPort();
    term = FakeTermSessionPort();
    voice = FakeVoice();
    sync = _Sync(tmp.path)..status = StateStatus.connected;
    sent = [];
    failSend = false;
    hang = null;
    s = MainState(
        hub: hub,
        data: DataDir(tmp.path),
        prefs: UiPrefs()..termFit = true,
        port: port,
        termPort: term,
        voice: withVoice ? voice : null,
        stateSync: sync,
        unlockStore: UnlockStore(supported: false, memory: false));
    s.probes['m1'] = DeviceProbe(Lamp.active, '在线', apps: const AppList('m1', 'lan', [], capabilities: {'reply': true}));
    nav = PhoneNav(s, send: (target, {seq, text, enter = false, keys = const []}) async {
      sent.add({'seq': seq, 'text': text, 'enter': enter, 'keys': keys});
      if (hang != null) await hang!.future;
      if (failSend) throw Exception('x');
    });
    t.onSend = (m) {
      if (m['cmd'] == 'open') {
        t.emit({'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'req': m['req'], 'port': 5001, 'token': 'tk'});
      }
    };
    t.emit({
      'event': 'terms', 'id': 'm1', 'path': 'lan', 'hosts': [],
      'terms': [
        {
          'id': 'term:pty:a', 'name': 'a', 'command': 'zsh', 'activity': 1, 'unread': false, 'reply': true,
          'fg': 'claude',
          if (card) 'ps': {'state': 'blocked', 'seq': 4, 'kind': 'permission', 'msg': 'approve plan', 'app': 'claude-code', 'since': 10},
        }
      ],
    });
    if (card) {
      sync.rows = [
        {'t': 'emit', 'level': 'info', 'id': 'm1', 'key': 'plan:term:pty:a', 'session': 'term:pty:a', 'text': '- 甲\n- 乙', 'at': 12, 'eid': 'e1'},
      ];
    }
    await tester.runAsync(flush);
    await tester.runAsync(() async {
      s.openOrSwitch('m1', app, app);
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    nav.enter('m1/$app');
    await tester.pumpWidget(MaterialApp(theme: themeDataFor(RappTheme.matrix), home: PhoneSessionView(state: s, nav: nav)));
    if (app.startsWith('term:')) {
      final panes = [
        TermPane(id: '%3', win: '@1', window: '@1', title: '', command: 'zsh', cols: 80, rows: 24, dead: false, active: true),
      ];
      term.paneLists[1] = panes;
      term.play(const ReadyEvent(1, 'zsh'));
      term.play(WindowsEvent(1, [win(3)]));
      term.play(const TrafficEvent(1, 0, 1));
    } else {
      port.emit(const ReadyEvent(1, 'Safari'));
      port.emit(WindowsEvent(1, [win(5, texture: 42)]));
    }
    await tester.runAsync(() async {
      for (var i = 0; i < 4; i++) {
        await flush();
      }
    });
    if (card) sync.push();
    await tester.pump();
    await tester.pump();
  }

  /// The waiting plan question again, as number [seq].
  Future<void> pushQuestion(WidgetTester tester, int seq) async {
    await tester.runAsync(() async {
      t.emit({
        'event': 'terms', 'id': 'm1', 'path': 'lan', 'hosts': [],
        'terms': [
          {
            'id': 'term:pty:a', 'name': 'a', 'command': 'zsh', 'activity': 1, 'unread': false, 'reply': true,
            'fg': 'claude',
            'ps': {'state': 'blocked', 'seq': seq, 'kind': 'permission', 'msg': 'approve plan', 'app': 'claude-code', 'since': 10},
          }
        ],
      });
      await flush();
    });
    await tester.pump();
  }

  List<Map<String, Object?>> views() => [for (final c in term.calls) if (c.$1 == 'view') c.$2];
  final raw = find.text('看原样');
  final back = find.text('看阅读视图');

  testWidgets('term opens in reading view', (tester) async {
    await boot(tester);
    expect(find.byType(PhoneReadingView), findsOneWidget);
    expect(raw, findsOneWidget);
    // The stage is mounted, but not shown.
    expect(find.byType(TermStage), findsNothing);
    expect(find.byType(TermStage, skipOffstage: false), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('看原样 toggles to the stage', (tester) async {
    await boot(tester);
    expect(views(), isNotEmpty);
    final stageState = tester.state(find.byType(TermStage, skipOffstage: false));
    final nViews = views().length;
    await tester.tap(raw);
    await tester.pump();
    expect(find.byType(TermStage), findsOneWidget);
    expect(find.byType(PhoneReadingView), findsNothing);
    expect(back, findsOneWidget);
    expect(identical(tester.state(find.byType(TermStage)), stageState), isTrue);
    await tester.tap(back);
    await tester.pump();
    expect(find.byType(PhoneReadingView), findsOneWidget);
    await tester.tap(raw);
    await tester.pump();
    await tester.tap(back);
    await tester.pump();
    // The same State all along: nothing was remounted, so no fresh view went out.
    expect(identical(tester.state(find.byType(TermStage, skipOffstage: false)), stageState), isTrue);
    expect(views().length, nViews);
    expect(views().every((v) => v['fit'] == false), isTrue);
    expect(term.calls.where((c) => c.$1 == 'resize'), isEmpty);
    expect(t.sent.where((m) => m['cmd'] == 'resize'), isEmpty);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('one tidy card for the session, not two', (tester) async {
    await boot(tester);
    s.tidyOf(s.currentRemote!.sid).begin('嗯那个我们明天开会', VoicePick.send);
    await tester.pump();
    expect(find.byType(VoiceTidyCard, skipOffstage: false), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a key taken over by a new PhoneVoice survives the old one disposing', (tester) async {
    await boot(tester);
    Widget pv(Key k, String tag) => PhoneVoice(
          key: k,
          state: s,
          key2: 'K',
          send: (text, v) {
            sent.add({'text': tag});
            return null;
          },
          edit: (_) {},
          builder: (context, hold) => const SizedBox(),
        );
    await tester.pumpWidget(MaterialApp(home: pv(const Key('a'), 'a')));
    final a = s.voiceSends['K'];
    await tester.pumpWidget(MaterialApp(home: pv(const Key('b'), 'b')));
    expect(s.voiceSends['K'], isNotNull);
    expect(identical(s.voiceSends['K'], a), isFalse);
    s.voiceSends['K']!('x', const VoiceOrigin());
    expect(sent.last, {'text': 'b'});
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(s.voiceSends.containsKey('K'), isFalse);
  });

  testWidgets('看原样 with a zoomed terminal shows 还原, reading does not', (tester) async {
    await boot(tester);
    final rs = s.currentRemote!;
    const stage = Size(390, 700);
    rs.zoomOf(3).zoomTo(2, const Offset(200, 300), fitRect(const Size(100, 100), stage), stage);
    await tester.pump();
    expect(find.byKey(const Key('zoom-reset')), findsNothing);
    await tester.tap(raw);
    await tester.pump();
    final reset = find.byKey(const Key('zoom-reset'));
    expect(reset, findsOneWidget);
    expect(tester.getSize(reset).shortestSide, greaterThanOrEqualTo(56));
    await tester.tap(reset);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(rs.currentZoomed, isFalse);
    expect(reset, findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('pinned card at the bottom', (tester) async {
    await boot(tester, card: true);
    expect(find.byType(ReplyActions), findsOneWidget);
    final card = tester.getRect(find.byType(ReplyActions));
    final bar = tester.getRect(find.byKey(const Key('composer-open')));
    expect(card.bottom, lessThanOrEqualTo(bar.top));
    await tester.pump(const Duration(seconds: 4));
  });

  Future<void> hold(WidgetTester tester, Finder f, String words) async {
    voice.stopResult = words;
    final g = await tester.startGesture(tester.getCenter(f));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('reply bar hold routes to replies.say', (tester) async {
    await boot(tester);
    final sid = s.currentRemote!.sid;
    expect(s.voiceSends.containsKey(sid), isTrue);
    expect(find.text('按住说话，回一句'), findsOneWidget);
    final before = term.calls.length;
    await hold(tester, find.byKey(const Key('phone-voice')), '好的，继续');
    expect(sent, [
      {'seq': null, 'text': '好的，继续', 'enter': true, 'keys': <String>[]}
    ]);
    // No view, paste, keys or resize went to the terminal; the outcome line says it went.
    expect(term.calls.skip(before).where((c) => c.$1 != 'composer'), isEmpty);
    await tester.pump(const Duration(seconds: 4));
    // Leaving the page takes the key away.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(s.voiceSends.containsKey(sid), isFalse);
  });

  testWidgets('a failed say shows its word and 进去看 above the bar', (tester) async {
    await boot(tester);
    failSend = true;
    await hold(tester, find.byKey(const Key('phone-voice')), '好的');
    expect(find.text('没成功，进去看看'), findsOneWidget);
    await tester.tap(find.text('进去看'));
    await tester.pump();
    expect(find.byType(TermStage), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('type square opens the composer', (tester) async {
    await boot(tester);
    final sq = find.byKey(const Key('composer-open'));
    expect(tester.getSize(sq), const Size(64, 64));
    expect(find.bySemanticsLabel('打字输入'), findsOneWidget);
    await tester.tap(sq);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(s.currentRemote!.composer.open, isTrue);
    expect(find.byKey(const Key('composer-field')), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('edge swipe returns only in reading view', (tester) async {
    await boot(tester);
    await tester.dragFrom(const Offset(5, 400), const Offset(120, 0));
    await tester.pump();
    expect(nav.now, PhoneView.home);
  });

  testWidgets('edge swipe does nothing in the raw view or short of 80', (tester) async {
    await boot(tester);
    await tester.dragFrom(const Offset(5, 400), const Offset(60, 0));
    await tester.pump();
    expect(nav.now, PhoneView.session);
    await tester.tap(raw);
    await tester.pump();
    await tester.dragFrom(const Offset(5, 400), const Offset(120, 0));
    await tester.pump();
    expect(nav.now, PhoneView.session);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('picture has no 看原样 and no edge swipe', (tester) async {
    await boot(tester, app: 'Safari');
    expect(raw, findsNothing);
    expect(find.byKey(const Key('edge-back')), findsNothing);
    await tester.dragFrom(const Offset(5, 400), const Offset(120, 0));
    await tester.pump();
    expect(nav.now, PhoneView.session);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('no recognizer shows only the type square', (tester) async {
    await boot(tester, withVoice: false);
    expect(find.byKey(const Key('phone-voice')), findsNothing);
    expect(find.text('按住说话，回一句'), findsNothing);
    expect(find.byKey(const Key('composer-open')), findsOneWidget);
    expect(s.voiceSends, isEmpty);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the reply bar refuses while the session waits; the card keeps its buttons', (tester) async {
    await boot(tester, card: true);
    expect(find.text('同意'), findsOneWidget);
    final before = t.sent.length;
    await hold(tester, find.text('按住说话，回一句'), '好的');
    expect(sent, isEmpty);
    expect(t.sent.skip(before).where((m) => m['cmd'] == 'reply_term'), isEmpty);
    expect(find.text('先点上面卡片的按钮'), findsOneWidget);
    expect(find.text('同意'), findsOneWidget);
    // A new question takes the word away.
    await pushQuestion(tester, 5);
    expect(find.text('先点上面卡片的按钮'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a 要改 hold across a new question sends nothing', (tester) async {
    await boot(tester, card: true);
    voice.stopResult = '改一下';
    final g = await tester.startGesture(tester.getCenter(find.text('要改')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    await pushQuestion(tester, 5);
    // The card of the new question is there, and the hold went with the old one.
    expect(find.text('要改'), findsOneWidget);
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(sent, isEmpty);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a failure word on the pinned card is the home card\'s too, and a new question takes it from both', (tester) async {
    await boot(tester, card: true);
    failSend = true;
    await tester.tap(find.text('同意'));
    await tester.pump();
    expect(sent, hasLength(1));
    expect(find.text('没成功，进去看看'), findsOneWidget);
    expect(find.text('同意'), findsNothing);
    Widget home() => MaterialApp(theme: themeDataFor(RappTheme.matrix), home: Scaffold(resizeToAvoidBottomInset: false, body: HomeScreen(state: s, nav: nav)));
    Widget inSession() => MaterialApp(theme: themeDataFor(RappTheme.matrix), home: PhoneSessionView(state: s, nav: nav));
    await tester.pumpWidget(home());
    await tester.pump();
    expect(find.text('没成功，进去看看'), findsOneWidget);
    expect(find.text('同意'), findsNothing);
    await pushQuestion(tester, 5);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('没成功，进去看看'), findsNothing);
    expect(find.text('同意'), findsOneWidget);
    await tester.pumpWidget(inSession());
    await tester.pump();
    expect(find.text('没成功，进去看看'), findsNothing);
    expect(find.text('同意'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the reply bar keeps its session\'s secure-field check for the tidy', (tester) async {
    await boot(tester);
    s.setLlm(const LlmEndpoint(url: 'localhost:1', key: 'k'));
    final rs = s.currentRemote!;
    expect(s.voiceSends.containsKey(rs.sid), isTrue);
    expect(s.tidyOf(rs.sid).would(_long), isTrue);
    rs.secureFocus = true;
    expect(s.tidyOf(rs.sid).would(_long), isFalse);
    // A key with no session behind it (a card) tidies as before.
    s.voiceSends['card'] = (text, o) => null;
    expect(s.tidyOf('card').would(_long), isTrue);
    s.voiceSends.remove('card');
    rs.secureFocus = false;
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a refusal for the old question that comes after the new one leaves the new card its buttons', (tester) async {
    await boot(tester, card: true);
    final h = hang = Completer<void>();
    await tester.tap(find.text('同意'));
    await tester.pump();
    expect(sent, hasLength(1));
    expect(find.text('同意'), findsNothing);
    await pushQuestion(tester, 5);
    h.completeError(HubException('changed'));
    await tester.pump();
    await tester.pump();
    expect(find.text('它已经不在等这一问了'), findsNothing);
    expect(find.text('同意'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('同意'), findsOneWidget);
  });
}
