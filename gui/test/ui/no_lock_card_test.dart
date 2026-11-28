import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/load_model.dart';
import 'package:rapp/ui/no_lock_card.dart';
import 'package:rapp/ui/tokens.dart';

import 'helpers.dart';

DeviceLoad noLockLoad({bool? on, bool held = true}) => DeviceLoad(at: 1, term: true, noLock: on, noLockHeld: held);

const _off = '没人连着时，会按系统设置熄屏、锁屏';
const _held = '一直亮着，不会自动锁屏';
const _lid = '合上笔记本盖子仍会睡眠';
const _retry = '没能保持唤醒，正在重试';

void main() {
  Future<void> show(WidgetTester tester, DeviceLoad? load,
      {bool mac = true, Future<void> Function(bool on)? onSet, void Function(String)? say}) async {
    await tester.pumpWidget(wrap(SizedBox(
      width: 220,
      child: NoLockCard(id: 'm1', load: load, mac: mac, onSet: onSet ?? (_) async {}, say: say ?? (_) {}),
    )));
  }

  Switch sw(WidgetTester tester) => tester.widget<Switch>(find.byKey(const Key('no-lock-switch-m1')));

  testWidgets('no_lock_card_texts', (tester) async {
    await show(tester, noLockLoad(on: false));
    expect(find.text('不锁屏'), findsOneWidget);
    expect(find.text(_off), findsOneWidget);
    expect(sw(tester).value, isFalse);

    await show(tester, noLockLoad(on: true));
    expect(find.text(_held), findsOneWidget);
    expect(find.text(_lid), findsOneWidget);
    expect(find.text(_off), findsNothing);
    expect(sw(tester).value, isTrue);

    await show(tester, noLockLoad(on: true), mac: false);
    expect(find.text(_held), findsOneWidget);
    expect(find.text(_lid), findsNothing);

    await show(tester, noLockLoad(on: true, held: false));
    expect(find.text(_retry), findsOneWidget);
    expect(find.text(_held), findsNothing);
    final t = RappTokens.of(tester.element(find.byType(NoLockCard)));
    expect(tester.widget<Text>(find.text(_retry)).style!.color, t.warn);
  });

  testWidgets('no_lock_card_absent_without_key', (tester) async {
    await show(tester, noLockLoad(on: null));
    expect(find.byKey(const Key('no-lock-card-m1')), findsNothing);
    expect(find.text('不锁屏'), findsNothing);
    await show(tester, null);
    expect(find.byKey(const Key('no-lock-card-m1')), findsNothing);
    await show(tester, noLockLoad(on: false));
    expect(find.byKey(const Key('no-lock-card-m1')), findsOneWidget);
  });

  testWidgets('no_lock_card_busy_then_follows', (tester) async {
    final gate = Completer<void>();
    final asked = <bool>[];
    await show(tester, noLockLoad(on: false), onSet: (on) {
      asked.add(on);
      return gate.future;
    });
    await tester.tap(find.byKey(const Key('no-lock-switch-m1')));
    await tester.pump();
    expect(asked, [true]);
    expect(sw(tester).onChanged, isNull);
    expect(sw(tester).value, isFalse);
    gate.complete();
    await tester.pump();
    // The request went through: on, before the snapshot says so.
    expect(sw(tester).value, isTrue);
    expect(sw(tester).onChanged, isNotNull);
    // A snapshot that still says off within 15 s does not flip it back.
    await show(tester, noLockLoad(on: false), onSet: (_) async {});
    expect(sw(tester).value, isTrue);
    await show(tester, noLockLoad(on: true), onSet: (_) async {});
    expect(sw(tester).value, isTrue);
    // Followed: from here the snapshot rules.
    await show(tester, noLockLoad(on: false), onSet: (_) async {});
    expect(sw(tester).value, isFalse);
  });

  testWidgets('a pending value the snapshots never confirm goes after 15 s', (tester) async {
    await show(tester, noLockLoad(on: false));
    await tester.tap(find.byKey(const Key('no-lock-switch-m1')));
    await tester.pump();
    expect(sw(tester).value, isTrue);
    await tester.pump(const Duration(seconds: 14));
    await show(tester, noLockLoad(on: false));
    expect(sw(tester).value, isTrue);
    await tester.pump(const Duration(seconds: 2));
    await show(tester, noLockLoad(on: false));
    expect(sw(tester).value, isFalse);
  });

  testWidgets('no_lock_card_refusal_reverts', (tester) async {
    final said = <String>[];
    await show(tester, noLockLoad(on: false), onSet: (_) async => throw HubException('not supported'), say: said.add);
    await tester.tap(find.byKey(const Key('no-lock-switch-m1')));
    await tester.pump();
    await tester.pump();
    expect(said, ['这台设备不能改它的设置']);
    expect(sw(tester).value, isFalse);
    expect(sw(tester).onChanged, isNotNull);
  });

  testWidgets('another failure says 失败 and reverts', (tester) async {
    final said = <String>[];
    await show(tester, noLockLoad(on: true), onSet: (_) async => throw HubException('unknown op'), say: said.add);
    await tester.tap(find.byKey(const Key('no-lock-switch-m1')));
    await tester.pump();
    await tester.pump();
    expect(said, ['失败：unknown op']);
    expect(sw(tester).value, isTrue);
  });
}
