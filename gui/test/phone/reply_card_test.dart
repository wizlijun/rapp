import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/phone/home_model.dart';
import 'package:rapp/phone/hold_button.dart';
import 'package:rapp/phone/phone_voice.dart';
import 'package:rapp/phone/replies.dart';
import 'package:rapp/phone/reply_card.dart';
import 'package:rapp/phone/reply_model.dart';
import 'package:rapp/phone/widgets.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/unlock.dart';

import '../fakes.dart';

class _Replies extends PhoneReplies {
  _Replies(super.state);
  final calls = <({String id, int? seq, List<String> keys, String word})>[];
  final marked = <String>[];
  final outcomes = <String, ReplyOutcome>{};
  bool failNext = false;

  @override
  ReplyOutcome? outcomeOf(String itemId) => outcomes[itemId];

  @override
  Future<bool> keys(String itemId, ReplyTarget t, int? seq, List<String> keys, {required String doneWord}) async {
    calls.add((id: itemId, seq: seq, keys: keys, word: doneWord));
    if (failNext) outcomes[itemId] = const ReplyOutcome('没成功，进去看看', failed: true);
    return !failNext;
  }

  @override
  void markEid(String eid) => marked.add(eid);
}

const _id = 'term\nm1\nterm:pty:a';

HomeItem item({int seq = 1, List<String>? points, PointsBy? by, String? eid, HomeKind kind = HomeKind.waiting}) => HomeItem(
      kind: kind,
      id: _id,
      lamp: Lamp.active,
      what: '在等确认',
      program: 'claude',
      device: 'mini',
      line: 'x',
      since: 1,
      button: HomeButton.goLook,
      sessionKey: 'm1/a',
      seq: seq,
      points: points,
      pointsBy: by,
      pointsEid: eid,
    );

const _target = ReplyTarget('m1', 'term:pty:a');

void main() {
  late Directory tmp;
  late MainState s;
  late _Replies r;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('reply_card_test');
    final tr = FakeTransport();
    s = MainState(
        hub: HubClient(tr),
        data: DataDir(tmp.path),
        prefs: UiPrefs(),
        port: FakeSessionPort(),
        unlockStore: UnlockStore(supported: false, memory: false),
        termPort: FakeTermSessionPort());
    r = _Replies(s);
  });
  tearDown(() {
    r.dispose();
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Widget host(RappTheme th, Widget child) => MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: MaterialApp(theme: themeDataFor(th), home: Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: child)))),
      );

  ReplyActions actions(HomeItem it, CardReply c, {Widget Function(String, ReplyVoiceUse)? voice, VoidCallback? onGotIt}) =>
      ReplyActions(item: it, reply: c, replies: r, voice: voice, onGotIt: onGotIt, onGoLook: () {});

  CardReply approve({String? quote, String? plain, ({String word, String why})? risk, int seq = 1}) => CardReply(ReplyKind.approve,
      target: _target, seq: seq, allow: const ['1'], deny: const ['Esc'], quote: quote ?? 'ls', plain: plain, risk: risk);

  for (final th in RappTheme.values) {
    group(th.name, () {
      testWidgets('approve card has deny left allow right at 64', (tester) async {
        await tester.pumpWidget(host(th, actions(item(), approve())));
        final deny = tester.getRect(find.widgetWithText(PhoneHoldButton, '拒绝'));
        final allow = tester.getRect(find.widgetWithText(PhoneHoldButton, '允许'));
        expect(deny.right, lessThan(allow.left));
        expect(allow.left - deny.right, greaterThanOrEqualTo(12));
        expect(deny.height, 64);
        expect(allow.height, 64);
        await tester.tap(find.text('允许'));
        await tester.tap(find.text('拒绝'));
        expect(r.calls.map((c) => '${c.keys.join()}/${c.word}/${c.seq}').toList(), ['1/已允许/1', 'Esc/已拒绝/1']);
      });

      testWidgets('risky stripe says why', (tester) async {
        await tester.pumpWidget(host(th, actions(item(), approve(quote: 'git push', risk: (word: '撤不回', why: '推上去以后收不回来')))));
        expect(find.text('撤不回'), findsOneWidget);
        expect(find.text('推上去以后收不回来'), findsOneWidget);
        final warn = RappTokens.of(tester.element(find.text('撤不回'))).warn;
        final boxes = tester.widgetList<Container>(find.byType(Container)).where((c) {
          final d = c.decoration;
          return d is BoxDecoration && d.border is Border && (d.border! as Border).top.color == warn;
        });
        expect(boxes, isNotEmpty);
        final paint = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).where((p) => p.painter.runtimeType.toString() == '_StripePainter');
        expect(paint, isNotEmpty);
        // Risky: the first release arms, nothing is sent yet.
        await tester.tap(find.text('允许'));
        await tester.pump();
        expect(r.calls, isEmpty);
        expect(find.text(holdConfirmLabel), findsOneWidget);
        await tester.tap(find.text(holdConfirmLabel));
        expect(r.calls.single.keys, ['1']);
      });

      testWidgets('options numbered and vertical', (tester) async {
        final c = CardReply(ReplyKind.options, target: _target, seq: 1, options: const ['甲', '乙', '丙']);
        await tester.pumpWidget(host(th, actions(item(), c)));
        final tops = [for (final w in ['甲', '乙', '丙']) tester.getRect(find.widgetWithText(PhoneHoldButton, w))];
        for (var i = 1; i < 3; i++) {
          expect(tops[i].top - tops[i - 1].bottom, greaterThanOrEqualTo(12));
          expect(tops[i].left, tops[0].left);
        }
        expect(find.text('2'), findsOneWidget);
        await tester.tap(find.text('乙'));
        expect(r.calls.single.keys, ['2']);
        expect(r.calls.single.word, '已回复 2');
        expect(find.text('选项都不合适？按住说话，回一句。'), findsNothing);
      });

      testWidgets('review shows source label', (tester) async {
        final c = CardReply(ReplyKind.review, target: _target, seq: 1, planOk: const ['2'], planRevise: const ['3']);
        await tester.pumpWidget(host(th, actions(item(points: ['a', 'b'], by: PointsBy.agent, eid: 'e1'), c)));
        expect(find.textContaining('它自己写的要点'), findsOneWidget);
        await tester.pumpWidget(host(th, actions(item(points: ['a'], by: PointsBy.rule), c)));
        expect(find.textContaining('取自计划原文'), findsOneWidget);
        // No microphone: only 同意.
        expect(find.text('要改'), findsNothing);
        expect(tester.getRect(find.widgetWithText(PhoneHoldButton, '同意')).height, 64);
      });

      testWidgets('review with voice puts 要改 left of 同意; 同意 marks the row after a good send', (tester) async {
        final c = CardReply(ReplyKind.review, target: _target, seq: 1, planOk: const ['2'], planRevise: const ['3']);
        final used = <(String, ReplyVoiceUse)>[];
        await tester.pumpWidget(host(th, actions(item(points: ['a'], by: PointsBy.agent, eid: 'e1'), c, voice: (l, u) {
          used.add((l, u));
          return SizedBox(height: 64, child: Center(child: Text(l)));
        })));
        expect(used, [('要改', ReplyVoiceUse.revise)]);
        expect(tester.getRect(find.text('要改')).right, lessThan(tester.getRect(find.text('同意')).left));
        await tester.tap(find.text('同意'));
        await tester.pump();
        expect(r.calls.single.keys, ['2']);
        expect(r.calls.single.word, '已同意');
        expect(r.marked, ['e1']);
      });

      testWidgets('同意 that failed does not mark the row', (tester) async {
        r.failNext = true;
        final c = CardReply(ReplyKind.review, target: _target, seq: 1, planOk: const ['2'], planRevise: const ['3']);
        await tester.pumpWidget(host(th, actions(item(points: ['a'], by: PointsBy.agent, eid: 'e1'), c)));
        await tester.tap(find.text('同意'));
        await tester.pump();
        expect(r.calls, hasLength(1));
        expect(r.marked, isEmpty);
      });

      testWidgets('points are plain text', (tester) async {
        final c = CardReply(ReplyKind.review, target: _target, seq: 1, planOk: const ['2'], planRevise: const ['3']);
        await tester.pumpWidget(host(th, actions(item(points: ['[x](http://y)'], by: PointsBy.agent), c)));
        expect(find.text('[x](http://y)'), findsOneWidget);
        expect(find.byType(RichText).evaluate().where((e) => (e.widget as RichText).text.toPlainText().contains('[x](http://y)')), isNotEmpty);
        expect(find.byType(SelectableText), findsNothing);
        expect(find.byType(Link), findsNothing);
      });

      testWidgets('card swap mid-press sends nothing', (tester) async {
        var it = item(seq: 1);
        late StateSetter set;
        await tester.pumpWidget(host(th, StatefulBuilder(builder: (c, s) {
          set = s;
          return actions(it, approve(seq: it.seq!));
        })));
        final g = await tester.startGesture(tester.getCenter(find.widgetWithText(PhoneHoldButton, '允许')));
        await tester.pump();
        set(() => it = item(seq: 2));
        await tester.pump();
        await g.up();
        await tester.pump();
        expect(r.calls, isEmpty);
      });

      testWidgets('done card gotIt sends nothing to the terminal', (tester) async {
        var got = 0;
        final c = CardReply(ReplyKind.done, target: _target, seq: 1, voice: true);
        await tester.pumpWidget(host(th, actions(item(kind: HomeKind.done), c, onGotIt: () => got++)));
        expect(find.text('说一句'), findsNothing);
        await tester.tap(find.text('知道了'));
        expect(got, 1);
        expect(r.calls, isEmpty);
      });

      testWidgets('outcome replaces the buttons; failed has 进去看', (tester) async {
        r.outcomes[_id] = const ReplyOutcome('没成功，进去看看', failed: true);
        await tester.pumpWidget(host(th, actions(item(), approve())));
        expect(find.text('没成功，进去看看'), findsOneWidget);
        expect(find.text('允许'), findsNothing);
        expect(find.text('进去看'), findsOneWidget);
        expect(tester.getRect(find.text('没成功，进去看看')).height, greaterThan(0));
      });

      testWidgets('go-look only when reply is none', (tester) async {
        await tester.pumpWidget(host(th, PhoneCard(item: item(), onOpen: null, onButton: () {})));
        expect(find.text('进去看'), findsOneWidget);
        expect(find.byType(PhoneHoldButton), findsNothing);
      });

      testWidgets('no 安全 anywhere', (tester) async {
        final risk = (word: '撤不回', why: '推上去以后收不回来');
        for (final c in [
          approve(plain: '看文件', risk: risk, quote: 'git push'),
          CardReply(ReplyKind.options, target: _target, seq: 1, options: const ['甲', '乙']),
          CardReply(ReplyKind.review, target: _target, seq: 1, planOk: const ['2'], planRevise: const ['3']),
          CardReply(ReplyKind.done, target: _target, seq: 1),
        ]) {
          await tester.pumpWidget(host(th, actions(item(points: ['a'], by: PointsBy.agent), c, voice: (l, u) => Text(l))));
          for (final t in tester.widgetList<Text>(find.byType(Text))) {
            expect(t.data ?? t.textSpan?.toPlainText() ?? '', isNot(contains('安全')));
          }
        }
      });
    });
  }

  testWidgets('the question card has no hint and no 说一句 even with a voice builder; the done card keeps its 说一句', (tester) async {
    final c = CardReply(ReplyKind.options, target: _target, seq: 1, options: const ['甲']);
    await tester.pumpWidget(host(RappTheme.values.first, actions(item(), c, voice: (l, u) => Text('$l-${u.name}'))));
    expect(find.text('选项都不合适？按住说话，回一句。'), findsNothing);
    expect(find.text('说一句-say'), findsNothing);
    expect(find.text('甲'), findsOneWidget);
    final d = CardReply(ReplyKind.done, target: _target, seq: 1, voice: true);
    await tester.pumpWidget(host(RappTheme.values.first, actions(item(kind: HomeKind.done), d, voice: (l, u) => Text('$l-${u.name}'))));
    expect(find.text('说一句-say'), findsOneWidget);
  });
}
