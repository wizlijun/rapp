import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/app_profile.dart';
import 'package:rapp/embed/phrase_send.dart';
import 'package:rapp/embed/phrases.dart';
import 'package:rapp/embed/remote_session.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/embed/strip_cmds.dart';
import 'package:rapp/embed/strip_tools.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';

import '../fakes.dart';

void main() {
  late Directory tmp;
  late FakeSessionPort port;
  late FakeTransport tr;
  late MainState state;
  late RemoteSession rs;
  late int returns;
  var clock = DateTime(2026, 11, 22, 10);
  DateTime now() => clock;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('phrase_send_test');
    final t = tr = FakeTransport();
    final hub = HubClient(t);
    port = FakeSessionPort();
    state = MainState(hub: hub, data: DataDir(tmp.path), prefs: UiPrefs(), port: port);
    returns = 0;
    rs = RemoteSession(1, 'Safari', onReturn: () => returns++)
      ..setProfile(const ResolvedProfile(afterSend: AfterSend.none));
  });

  tearDown(() {
    rs.dispose();
    state.dispose();
    tmp.deleteSync(recursive: true);
  });

  int sends() => port.calls.where((c) => c.$1 == 'composer_send').length;
  PhraseOutcome tap(Phrase p) => sendPhrase(state: state, session: rs, port: port, p: p, now: now);

  test('a tap sends the text as its own round and presses Return even when 发送后 is 只贴', () {
    rs.composer.draft = '写了一半';
    rs.composer.open = true;
    expect(tap(const Phrase('继续')), PhraseOutcome.sent);
    expect(sends(), 1);
    expect(port.calls.last.$2.toString(), contains('继续'));
    rs.composer.done(1, null);
    expect(returns, 1);
    expect(rs.composer.draft, '写了一半');
    expect(rs.composer.open, isTrue, reason: 'the panel stays as it was');
  });

  test('a second tap within a second is ignored; after it, a busy round refuses', () {
    expect(tap(const Phrase('继续')), PhraseOutcome.sent);
    clock = clock.add(const Duration(milliseconds: 900));
    expect(tap(const Phrase('确认')), PhraseOutcome.tooSoon);
    clock = clock.add(const Duration(milliseconds: 200));
    expect(tap(const Phrase('确认')), PhraseOutcome.busy, reason: 'the first is still in flight');
    expect(phraseHint(PhraseOutcome.busy), '上一条还在发');
    expect(sends(), 1);
    rs.composer.done(1, null);
    expect(tap(const Phrase('确认')), PhraseOutcome.sent);
    expect(sends(), 2);
  });

  test('a failed round presses no Return', () {
    tap(const Phrase('继续'));
    rs.composer.done(0, '没有发出去');
    expect(returns, 0);
  });

  test('放进输入框 puts the text at the end of the draft, opens the panel and sends nothing', () async {
    rs.composer.draft = '先看看';
    expect(tap(const Phrase('按你推荐的来', put: true)), PhraseOutcome.put);
    await Future<void>.delayed(Duration.zero);
    expect(rs.composer.draft, '先看看\n按你推荐的来');
    expect(rs.composer.open, isTrue);
    expect(sends(), 0);
  });

  test('an ordinary send after a phrase follows 发送后 again', () {
    rs.setProfile(const ResolvedProfile(afterSend: AfterSend.pressReturn));
    tap(const Phrase('继续'));
    rs.composer.done(1, null);
    expect(returns, 1);
    rs.composer.submitText('普通的一句');
    rs.composer.done(1, null);
    expect(returns, 2);
    expect(rs.composer.open, isFalse, reason: 'collapsed by the ordinary after-send step');
  });

  group('strip commands', () {
    final claude = agentTools.firstWhere((t) => t.id == 'claude-code');
    final codex = agentTools.firstWhere((t) => t.id == 'codex');
    late FakeTermSessionPort tp;
    setUp(() {
      tp = FakeTermSessionPort()..seed(1);
    });

    int keyCalls() => tp.calls.where((c) => c.$1 == 'keys').length;
    PhraseOutcome cmd(StripCmd c, {AgentTool? tool, RemoteSession? session, SessionPort? p}) => sendStripCmd(
        state: state, session: session ?? rs, port: p ?? tp, c: c, tool: tool ?? claude, now: now);

    test('a text command is its own round with Return, draft and panel untouched', () {
      rs.composer.draft = '写了一半';
      rs.composer.open = true;
      expect(cmd(const StripCmd('new')), PhraseOutcome.sent);
      final sent = tp.calls.where((c) => c.$1 == 'paste').toList();
      expect(sent, hasLength(1));
      expect(sent.single.$2['data'], '/clear');
      rs.composer.done(1, null);
      expect(returns, 1);
      expect(rs.composer.draft, '写了一半');
      expect(rs.composer.open, isTrue);
    });

    test('a key command sends the wire key and no round', () {
      expect(cmd(const StripCmd('search')), PhraseOutcome.sent);
      expect(keyCalls(), 1);
      expect(tp.calls.last.$2['keys'], ['Ctrl-R']);
      expect(tp.calls.where((c) => c.$1 == 'paste'), isEmpty);
    });

    test('while a round is going both kinds are refused', () {
      rs.composer.submitText('先发的');
      expect(cmd(const StripCmd('search')), PhraseOutcome.busy);
      expect(cmd(const StripCmd('new')), PhraseOutcome.busy);
      expect(tp.calls.where((c) => c.$1 == 'keys' || c.$1 == 'paste'), isEmpty);
    });

    test('shares the one-second window with 常用语', () {
      expect(tap(const Phrase('继续')), PhraseOutcome.sent);
      rs.composer.done(1, null);
      clock = clock.add(const Duration(milliseconds: 500));
      expect(cmd(const StripCmd('new')), PhraseOutcome.tooSoon);
      expect(tp.calls.where((c) => c.$1 == 'paste'), isEmpty);
    });

    test('a tool without the command is missing, and says so', () {
      expect(cmd(const StripCmd('new', per: {'codex': null}), tool: codex), PhraseOutcome.missing);
      expect(stripHint(PhraseOutcome.missing, tool: codex), 'Codex 没有这个命令');
      expect(stripHint(PhraseOutcome.busy), '上一条还在发');
      expect(tp.calls.where((c) => c.$1 == 'keys' || c.$1 == 'paste'), isEmpty);
    });

    test('a key command on a port that is not a terminal is missing', () {
      expect(cmd(const StripCmd('search'), p: port), PhraseOutcome.missing);
    });

    testWidgets('offline refuses both kinds', (tester) async {
      tr.emit({'event': 'hosts', 'hosts': [{'id': '111', 'name': 'mini'}]});
      await tester.runAsync(() async {
        tr.onSend = (m) {
          if (m['cmd'] == 'open') {
            tr.emit({'event': 'opened', 'sid': 1, 'id': m['id'], 'app': m['app'], 'path': 'lan', 'port': 5001, 'token': 'tk', 'req': m['req']});
          }
        };
        state.openOrSwitch('111', 'Safari', 'Safari');
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      });
      port.emit(const DisconnectedEvent(1, 'connection closed'));
      expect(state.sendBlocked(1), isTrue);
      final s = state.currentRemote!;
      expect(cmd(const StripCmd('search'), session: s), PhraseOutcome.offline);
      expect(cmd(const StripCmd('new'), session: s), PhraseOutcome.offline);
      expect(tp.calls.where((c) => c.$1 == 'keys' || c.$1 == 'paste'), isEmpty);
    });
  });
}
