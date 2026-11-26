import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/wait_card.dart';
import 'package:rapp/ui/waits.dart';

import 'helpers.dart';

const _card = Key('wait-card');

void main() {
  late Waits w;
  setUp(() => w = Waits());
  tearDown(() => w.dispose());

  Widget stage({VoidCallback? onTap}) => SizedBox(
        width: 800,
        height: 600,
        child: Stack(children: [
          Positioned.fill(child: GestureDetector(key: const Key('under'), onTap: onTap, child: const ColoredBox(color: Colors.black))),
          Positioned.fill(child: WaitCard(waits: w)),
        ]),
      );

  testWidgets('wait_card_hidden_then_shown: appears past 300 ms and counts seconds', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    final hold = Completer<void>();
    unawaited(w.run('正在新建终端…', () => hold.future, detail: 'mini · 在「work」旁边'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(_card), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(_card), findsOneWidget);
    expect(find.text('正在新建终端…'), findsOneWidget);
    expect(find.text('mini · 在「work」旁边'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('2 秒'), findsOneWidget);
    hold.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_card), findsNothing);
  });

  testWidgets('wait_card_lets_taps_through: a tap on the card reaches what is under it', (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(stage(onTap: () => taps++)));
    unawaited(w.run('正在新建终端…', () => Completer<void>().future));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(tester.getCenter(find.byKey(_card)));
    expect(taps, 1);
  });

  testWidgets('long_outcome_wraps_within_card: the permission words fit in two lines', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    final words = MainState.newTermWords(HubException('macOS is asking on that Mac whether rApp may control Terminal'));
    w.run('正在新建终端…', () => Future<void>.error(HubException('x')), words: (_) => words, asks: (_) => true).ignore();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_card), findsOneWidget);
    expect(tester.getSize(find.byKey(_card)).width, lessThanOrEqualTo(420));
    final text = tester.widget<Text>(find.text(words));
    expect(text.maxLines, 2);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 9));
    expect(find.byKey(_card), findsNothing);
  });

  testWidgets('wait_card_more_line: queued ones are said under the first', (tester) async {
    await tester.pumpWidget(wrap(stage()));
    for (var i = 0; i < 3; i++) {
      unawaited(w.run('正在新建终端…', () => Completer<void>().future));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('正在新建终端…'), findsOneWidget);
    expect(find.text('还有 2 个排队'), findsOneWidget);
  });
}
