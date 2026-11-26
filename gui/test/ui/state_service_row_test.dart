import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/service_client.dart';
import 'package:rapp/state/service_switch.dart';
import 'package:rapp/ui/state_service_row.dart';

import 'helpers.dart';

class FakeSwitch implements ServiceSwitchApi {
  Future<Map<String, Object?>> Function(String? to, bool? on) onState =
      (to, on) async => {'ok': true, 'on': on ?? false};
  Future<String?> Function() onHost = () async => null;
  final calls = <String>[];

  @override
  Future<Map<String, Object?>> stateService({String? to, bool? on}) {
    calls.add('state $to $on');
    return onState(to, on);
  }

  @override
  Future<String?> stateHost() => onHost();
}

Widget row(FakeSwitch api, {String? to = '111111111', String? localId}) => wrap(
      StateServiceRow(key: UniqueKey(), api: api, to: to, nameOf: (id) => 'dev-$id', localId: localId),
    );

bool switchOn(WidgetTester tester) => tester.widget<Switch>(find.byType(Switch)).value;

void main() {
  for (final why in ['unknown op', 'old version']) {
    testWidgets('hidden when the device is too old ($why)', (tester) async {
      final api = FakeSwitch()..onState = (_, _) async => throw Exception(why);
      await tester.pumpWidget(row(api));
      await tester.pumpAndSettle();
      expect(find.text('状态服务'), findsNothing);
      expect(find.byType(Switch), findsNothing);
    });
  }

  testWidgets('shows on and running with the port', (tester) async {
    final api = FakeSwitch()..onState = (_, _) async => {'ok': true, 'on': true, 'running': true, 'port': 8102};
    await tester.pumpWidget(row(api));
    await tester.pumpAndSettle();
    expect(find.text('状态服务'), findsOneWidget);
    expect(find.text('运行中，端口 8102'), findsOneWidget);
    expect(switchOn(tester), isTrue);
  });

  testWidgets('on without a port yet says 启动中, an error says itself', (tester) async {
    final api = FakeSwitch()..onState = (_, _) async => {'ok': true, 'on': true, 'running': false};
    await tester.pumpWidget(row(api));
    await tester.pumpAndSettle();
    expect(find.text('启动中'), findsOneWidget);
    final bad = FakeSwitch()..onState = (_, _) async => {'ok': true, 'on': true, 'running': false, 'error': 'port taken'};
    await tester.pumpWidget(row(bad, to: '333333333'));
    await tester.pumpAndSettle();
    expect(find.text('port taken'), findsOneWidget);
  });

  testWidgets('turning on calls with on: true and shows the new state', (tester) async {
    final api = FakeSwitch()
      ..onState = (to, on) async =>
          on == true ? {'ok': true, 'on': true, 'running': true, 'port': 8102} : {'ok': true, 'on': false};
    await tester.pumpWidget(row(api));
    await tester.pumpAndSettle();
    expect(switchOn(tester), isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(api.calls, ['state 111111111 null', 'state 111111111 true']);
    expect(switchOn(tester), isTrue);
    expect(find.text('运行中，端口 8102'), findsOneWidget);
  });

  testWidgets('the switch is disabled while the call is out', (tester) async {
    final gate = Completer<Map<String, Object?>>();
    final api = FakeSwitch()
      ..onState = (to, on) => on == null ? Future.value({'ok': true, 'on': false}) : gate.future;
    await tester.pumpWidget(row(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    gate.complete({'ok': true, 'on': true});
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
  });

  testWidgets('a failed turn shows the reason and flips back', (tester) async {
    final api = FakeSwitch()
      ..onState = (to, on) async => on == true ? throw ServiceException('policy') : {'ok': true, 'on': false};
    await tester.pumpWidget(row(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.textContaining('没开成：'), findsOneWidget);
    expect(find.textContaining('对方的策略不允许远程设置'), findsOneWidget);
    expect(switchOn(tester), isFalse);
  });

  testWidgets('a failed turn off says 没关成', (tester) async {
    final api = FakeSwitch()
      ..onState = (to, on) async => on == false ? throw ServiceException('limit') : {'ok': true, 'on': true, 'running': true, 'port': 1};
    await tester.pumpWidget(row(api));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.textContaining('没关成：'), findsOneWidget);
    expect(switchOn(tester), isTrue);
  });

  testWidgets('names where the other one is', (tester) async {
    final api = FakeSwitch()..onHost = () async => '222222222';
    await tester.pumpWidget(row(api, localId: '999999999'));
    await tester.pumpAndSettle();
    expect(find.text('已经有一个在 dev-222222222 上'), findsOneWidget);

    final here = FakeSwitch()..onHost = () async => '999999999';
    await tester.pumpWidget(row(here, to: '333333333', localId: '999999999'));
    await tester.pumpAndSettle();
    expect(find.text('已经有一个在 本机 上'), findsOneWidget);

    final self = FakeSwitch()..onHost = () async => '444444444';
    await tester.pumpWidget(row(self, to: '444444444', localId: '999999999'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已经有一个在'), findsNothing);
  });

  testWidgets('for this device (to null) the host is compared with localId', (tester) async {
    final api = FakeSwitch()..onHost = () async => '999999999';
    await tester.pumpWidget(row(api, to: null, localId: '999999999'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已经有一个在'), findsNothing);
    final other = FakeSwitch()..onHost = () async => '555555555';
    await tester.pumpWidget(row(other, to: null, localId: '999999999'));
    await tester.pumpAndSettle();
    expect(find.text('已经有一个在 dev-555555555 上'), findsOneWidget);
  });
}
