import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/ui/access_setup.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late List<HubAccess> done;

  setUp(() {
    t = FakeTransport();
    hub = HubClient(t);
    done = [];
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(wrap(AccessSetup(hub: hub, onDone: done.add)));
  }

  FilledButton go(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(const Key('access-go')));

  testWidgets('接入 sends set_access with both fields and calls onDone', (tester) async {
    t.onSend = (cmd) {
      if (cmd['cmd'] == 'set_access') {
        t.emit({'event': 'access', 'relay': cmd['relay'], 'has_key': true, 'name': 'iPad', 'req': cmd['req']});
      }
    };
    await pump(tester);
    expect(find.text('接入点'), findsOneWidget);
    expect(find.text('key'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('access-relay')), 'r:1');
    await tester.enterText(find.byKey(const Key('access-key')), 'k');
    await tester.pump();
    await tester.tap(find.byKey(const Key('access-go')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(t.sent.where((c) => c['cmd'] == 'set_access').single,
        {'cmd': 'set_access', 'relay': 'r:1', 'key': 'k', 'req': anything});
    expect(done, [const HubAccess('r:1', true, 'iPad')]);
  });

  testWidgets('the key field hides what is typed', (tester) async {
    await pump(tester);
    final key = tester.widget<TextField>(
        find.descendant(of: find.byKey(const Key('access-key')), matching: find.byType(TextField)).first);
    expect(key.obscureText, isTrue);
  });

  testWidgets('bad key shows key 不对 and does not call onDone', (tester) async {
    t.onSend = (cmd) {
      if (cmd['cmd'] == 'set_access') t.emit({'event': 'error', 'error': 'bad key', 'req': cmd['req']});
    };
    await pump(tester);
    await tester.enterText(find.byKey(const Key('access-relay')), 'r:1');
    await tester.enterText(find.byKey(const Key('access-key')), 'nope');
    await tester.pump();
    await tester.tap(find.byKey(const Key('access-go')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.text('key 不对'), findsOneWidget);
    expect(done, isEmpty);
  });

  testWidgets('接入 is grey while 接入点 is empty', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const Key('access-key')), 'k');
    await tester.pump();
    expect(go(tester).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('access-relay')), '  ');
    await tester.pump();
    expect(go(tester).onPressed, isNull, reason: 'blank is empty');
    await tester.enterText(find.byKey(const Key('access-relay')), 'r:1');
    await tester.pump();
    expect(go(tester).onPressed, isNotNull);
  });

  testWidgets('the 接入 button is at least 48 tall', (tester) async {
    await pump(tester);
    expect(tester.getSize(find.byKey(const Key('access-go'))).height, greaterThanOrEqualTo(48));
  });
}
