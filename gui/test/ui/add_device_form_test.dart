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
}
