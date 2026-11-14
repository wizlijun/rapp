import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/pages/local_section.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/service_client.dart';

import 'service_client_test.dart' show FakeService, until;
import 'ui/helpers.dart';

void main() {
  late Directory tmp;
  late FakeService svc;
  late ServiceMonitor m;
  late List<String> copied;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rapp-local-id');
    Directory('${tmp.path}/local').createSync();
    copied = [];
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.runAsync(() async {
      await svc.start();
      m = ServiceMonitor(readToken: () async => 'tok', port: svc.port, retry: const Duration(milliseconds: 50));
      m.start();
      await until(() => m.status != null);
    });
    addTearDown(() async {
      m.dispose();
      await tester.runAsync(svc.stop);
    });
    await tester.pumpWidget(wrap(SingleChildScrollView(
      child: LocalSection(platform: TargetPlatform.windows, monitor: m, control: null, data: DataDir(tmp.path)),
    )));
    await tester.pump();
  }

  testWidgets('the password is hidden until revealed, and its length is not shown', (tester) async {
    svc = FakeService('tok');
    await pump(tester);
    expect(find.text('ab12cd34'), findsNothing);
    expect(find.text(passwordMask), findsOneWidget);

    await tester.tap(find.byKey(const Key('password-reveal')));
    await tester.pump();
    expect(find.text('ab12cd34'), findsOneWidget);

    await tester.tap(find.byKey(const Key('password-reveal')));
    await tester.pump();
    expect(find.text('ab12cd34'), findsNothing);
  });

  testWidgets('the password copies without being shown', (tester) async {
    svc = FakeService('tok');
    await pump(tester);
    await tester.tap(find.byKey(const Key('copy-password')));
    await tester.pump();
    expect(copied, ['ab12cd34']);
    expect(find.text('ab12cd34'), findsNothing);
    expect(find.text('已复制密码'), findsOneWidget);
  });

  testWidgets('the bare ID has a copy button', (tester) async {
    svc = FakeService('tok');
    await pump(tester);
    expect(find.text('123456789'), findsOneWidget);
    await tester.tap(find.byKey(const Key('copy-id-0')));
    await tester.pump();
    expect(copied, ['123456789']);
    expect(find.text('已复制 ID'), findsOneWidget);
  });

  testWidgets('relay row shows address and state', (tester) async {
    svc = FakeService('tok')..extraStatus = {'relay_addr': 'vps:22026', 'relay': 'connected', 'has_key': true};
    await pump(tester);
    expect(find.text('中继'), findsOneWidget);
    expect(find.text('vps:22026'), findsOneWidget);
    expect(find.text('已连接'), findsOneWidget);
    expect(find.byKey(const Key('edit-relay')), findsOneWidget);
  });

  testWidgets('relay states read in words', (tester) async {
    svc = FakeService('tok')..extraStatus = {'relay_addr': 'vps:22026', 'relay': 'error', 'relay_error': 'relay unreachable: x'};
    await pump(tester);
    expect(find.textContaining('出错：中继连不上'), findsOneWidget);
  });

  testWidgets('no relay set reads 未设置', (tester) async {
    svc = FakeService('tok');
    await pump(tester);
    expect(find.text('未设置'), findsWidgets);
    expect(find.byKey(const Key('edit-relay')), findsOneWidget);
  });

  testWidgets('key is masked until shown', (tester) async {
    svc = FakeService('tok')..extraStatus = {'relay_addr': 'vps:22026', 'relay': 'connected', 'has_key': true};
    await pump(tester);
    expect(find.text('KEY-TEXT-123'), findsNothing);
    expect(find.text('••••••'), findsOneWidget);
    await tester.tap(find.text('显示'));
    await tester.runAsync(() => until(() => svc.received.any((c) => c['cmd'] == 'show_key')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('KEY-TEXT-123'), findsOneWidget);
    expect(find.byKey(const Key('copy-key')), findsOneWidget);
  });

  testWidgets('editing relay calls set_relay', (tester) async {
    svc = FakeService('tok');
    await pump(tester);
    await tester.tap(find.byKey(const Key('edit-relay')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '接入点'), 'vps:22026');
    await tester.enterText(find.widgetWithText(TextField, 'key'), 'K1');
    await tester.tap(find.text('保存'));
    await tester.runAsync(() => until(() => svc.received.any((c) => c['cmd'] == 'set_relay')));
    await tester.pumpAndSettle();
    expect(svc.received.lastWhere((c) => c['cmd'] == 'set_relay'),
        {'cmd': 'set_relay', 'relay': 'vps:22026', 'key': 'K1'});
  });

  testWidgets('bad key error is shown', (tester) async {
    svc = FakeService('tok')..replies['set_relay'] = {'ok': false, 'error': 'bad key'};
    await pump(tester);
    await tester.tap(find.byKey(const Key('edit-relay')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '接入点'), 'vps:22026');
    await tester.enterText(find.widgetWithText(TextField, 'key'), 'bad');
    await tester.tap(find.text('保存'));
    await tester.runAsync(() => until(() => svc.received.any((c) => c['cmd'] == 'set_relay')));
    await tester.pumpAndSettle();
    expect(find.text('key 不对'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('ids with relay: bare id first', (tester) async {
    svc = FakeService('tok')
      ..extraStatus = {'relay_addr': 'vps:22026'}
      ..lanIds = ['123456789@192.168.1.5'];
    await pump(tester);
    await tester.tap(find.byKey(const Key('copy-id-0')));
    await tester.pump();
    expect(copied, ['123456789']);
    expect(find.text('123456789@192.168.1.5'), findsOneWidget);
  });

  testWidgets('every LAN ID has its own copy button', (tester) async {
    svc = FakeService('tok')
      ..lanIds = ['123456789@192.168.1.5', '123456789@10.0.0.7'];
    await pump(tester);
    expect(find.text('123456789@192.168.1.5'), findsOneWidget);
    expect(find.text('123456789@10.0.0.7'), findsOneWidget);
    await tester.tap(find.byKey(const Key('copy-id-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('copy-id-0')));
    await tester.pump();
    expect(copied, ['123456789@10.0.0.7', '123456789@192.168.1.5']);
  });
}
