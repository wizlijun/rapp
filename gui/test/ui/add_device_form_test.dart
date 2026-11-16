import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/add_device_form.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late FakeTransport t;
  late List<String> added;

  setUp(() {
    t = FakeTransport();
    added = [];
    t.onSend = (cmd) {
      if (cmd['cmd'] == 'add_host') {
        t.emit({'event': 'host_added', 'req': cmd['req'], 'id': cmd['id'], 'name': 'mac'});
      }
    };
  });

  Future<void> pump(WidgetTester tester, {bool relaySet = false}) => tester.pumpWidget(wrap(SizedBox(
        width: 420,
        child: AddDeviceForm(hub: HubClient(t), onAdded: added.add, relaySet: relaySet),
      )));

  testWidgets('without a relay the form asks for ID@IP and a password', (tester) async {
    await pump(tester);
    expect(find.text('对方的 ID@IP'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
  });

  testWidgets('with a relay the form asks for an ID and the password may be empty', (tester) async {
    await pump(tester, relaySet: true);
    expect(find.text('对方的 ID'), findsOneWidget);
    expect(find.text('对方的 ID@IP'), findsNothing);
    expect(find.text('有 key 时不用填'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('add-id')), '222');
    await tester.tap(find.byKey(const Key('add-button')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    final add = t.sent.firstWhere((m) => m['cmd'] == 'add_host');
    expect(add['id'], '222');
    expect(add['password'], '');
    expect(added, ['222']);
  });

  testWidgets('an add error is shown in words', (tester) async {
    t.onSend = (cmd) => t.emit({'event': 'error', 'req': cmd['req'], 'error': 'unknown id'});
    await pump(tester, relaySet: true);
    await tester.enterText(find.byKey(const Key('add-id')), '999');
    await tester.tap(find.byKey(const Key('add-button')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('没有这个 ID'), findsOneWidget);
  });
  for (final entry in {
    '111@10.0.0.2': 22028,
    '111@10.0.0.2:23128': 23128,
    '111@[2001:db8::2]:24128': 24128,
    '111@2001:db8::2': 22028,
  }.entries) {
    testWidgets('timeout for ${entry.key} names its remote UDP port', (tester) async {
      t.onSend = (cmd) => t.emit({'event': 'error', 'req': cmd['req'], 'error': 'timed out'});
      await pump(tester);
      await tester.enterText(find.byKey(const Key('add-id')), entry.key);
      await tester.tap(find.byKey(const Key('add-button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('UDP ${entry.value}'), findsOneWidget);
      expect(find.textContaining('原因尚未确定'), findsOneWidget);
      expect(find.textContaining('网络隔离'), findsOneWidget);
      expect(find.textContaining('22029'), findsNothing);
      expect(find.text('密码不对'), findsNothing);
    });
  }

  testWidgets('bare ID relay timeout checks relay access without inventing a peer port', (tester) async {
    t.onSend = (cmd) => t.emit({'event': 'error', 'req': cmd['req'], 'error': 'relay unreachable: timed out'});
    await pump(tester, relaySet: true);
    await tester.enterText(find.byKey(const Key('add-id')), '111');
    await tester.tap(find.byKey(const Key('add-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('中继配置的端口'), findsOneWidget);
    expect(find.textContaining('22028'), findsNothing);
  });

  testWidgets('timeout uses the submitted address even if the field is edited while waiting', (tester) async {
    Map<String, dynamic>? request;
    t.onSend = (cmd) => request = cmd;
    await pump(tester, relaySet: true);
    await tester.enterText(find.byKey(const Key('add-id')), '111@10.0.0.2:23128');
    await tester.tap(find.byKey(const Key('add-button')));
    await tester.enterText(find.byKey(const Key('add-id')), '222@10.0.0.3:24128');
    t.emit({'event': 'error', 'req': request!['req'], 'error': 'no reply'});
    await tester.pumpAndSettle();
    expect(find.textContaining('UDP 23128'), findsOneWidget);
    expect(find.textContaining('UDP 24128'), findsNothing);
  });

}
