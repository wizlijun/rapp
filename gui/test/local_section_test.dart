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

  testWidgets('connecting after a failure shows why', (tester) async {
    svc = FakeService('tok')
      ..extraStatus = {'relay_addr': 'vps:22026', 'has_key': true, 'relay': 'connecting', 'relay_error': 'limit'};
    await pump(tester);
    expect(find.text('连接中：超出中继的限制，稍后再试'), findsOneWidget);
  });

  testWidgets('connecting the first time reads 连接中', (tester) async {
    svc = FakeService('tok')..extraStatus = {'relay_addr': 'vps:22026', 'has_key': true, 'relay': 'connecting'};
    await pump(tester);
    expect(find.text('连接中'), findsOneWidget);
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

  testWidgets('editing only the address keeps the key', (tester) async {
    svc = FakeService('tok')..extraStatus = {'relay_addr': 'vps:22026', 'relay': 'connected', 'has_key': true};
    await pump(tester);
    await tester.tap(find.byKey(const Key('edit-relay')));
    await tester.runAsync(() => until(() => svc.received.any((c) => c['cmd'] == 'show_key')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '接入点'), 'vps2:22026');
    await tester.tap(find.text('保存'));
    await tester.runAsync(() => until(() => svc.received.any((c) => c['cmd'] == 'set_relay')));
    await tester.pumpAndSettle();
    expect(svc.received.lastWhere((c) => c['cmd'] == 'set_relay'),
        {'cmd': 'set_relay', 'relay': 'vps2:22026', 'key': 'KEY-TEXT-123'});
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

  group('key changed', () {
    const changed = {'relay_addr': 'vps:22026', 'relay': 'error', 'relay_error': 'key changed', 'has_key': true};

    testWidgets('shows the warning, the explanation and the button', (tester) async {
      svc = FakeService('tok')..extraStatus = changed;
      await pump(tester);
      expect(find.text('安全变更：中继换了 key'), findsOneWidget);
      expect(find.text('这台设备已经和中继断开。请向管理中继的人要新 key，再输入。'), findsOneWidget);
      expect(find.byKey(const Key('enter-new-key')), findsOneWidget);
      expect(find.text('输入新 key'), findsOneWidget);
    });

    testWidgets('saving calls set_relay with the old address and the trimmed key; a wrong one reads 新 key 不对',
        (tester) async {
      svc = FakeService('tok')..extraStatus = changed;
      await pump(tester);
      await tester.tap(find.byKey(const Key('enter-new-key')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '输入新 key'), findsOneWidget);
      expect(tester.widgetList<TextField>(find.byType(TextField)).length, 1);
      await tester.enterText(find.byType(TextField), '  NEWKEY\n');
      // set_relay refreshes the status; the relay rejects the new key too.
      svc.extraStatus = {...changed, 'relay_error': 'bad key'};
      await tester.tap(find.text('保存'));
      await tester.runAsync(() => until(() => svc.received.any((c) => c['cmd'] == 'set_relay')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(svc.received.lastWhere((c) => c['cmd'] == 'set_relay'),
          {'cmd': 'set_relay', 'relay': 'vps:22026', 'key': 'NEWKEY'});
      expect(find.byType(AlertDialog), findsNothing);

      await tester.pump();
      expect(find.text('出错：新 key 不对'), findsOneWidget);
      expect(find.text('安全变更：中继换了 key'), findsNothing);
      expect(find.byKey(const Key('enter-new-key')), findsOneWidget);
    });

    testWidgets('bad key without entering a new one keeps the old text and shows the button', (tester) async {
      svc = FakeService('tok')..extraStatus = {...changed, 'relay_error': 'bad key'};
      await pump(tester);
      expect(find.text('出错：key 不对'), findsOneWidget);
      expect(find.text('出错：新 key 不对'), findsNothing);
      expect(find.byKey(const Key('enter-new-key')), findsOneWidget);
    });

    testWidgets('no relay: no prompt and no button', (tester) async {
      svc = FakeService('tok');
      await pump(tester);
      expect(find.text('安全变更：中继换了 key'), findsNothing);
      expect(find.byKey(const Key('enter-new-key')), findsNothing);
    });
  });

  testWidgets('with a relay the bare ID comes first and LAN IDs fold', (tester) async {
    svc = FakeService('tok')
      ..extraStatus = {'relay_addr': 'vps:22026', 'has_key': true}
      ..lanIds = ['123456789@192.168.1.5', '123456789@10.0.0.7'];
    await pump(tester);
    await tester.tap(find.byKey(const Key('copy-id-0')));
    await tester.pump();
    expect(copied, ['123456789']);
    expect(find.text('▸ 局域网地址（2 个）'), findsOneWidget);
    expect(find.text('123456789@192.168.1.5'), findsNothing);

    await tester.tap(find.byKey(const Key('lan-fold')));
    await tester.pump();
    expect(find.text('▾ 局域网地址（2 个）'), findsOneWidget);
    expect(find.text('123456789@192.168.1.5'), findsOneWidget);
    expect(find.text('123456789@10.0.0.7'), findsOneWidget);
    await tester.tap(find.byKey(const Key('copy-lan-1')));
    await tester.pump();
    expect(copied.last, '123456789@10.0.0.7');

    // Leaving the page and coming back: folded again.
    await tester.pumpWidget(wrap(const SizedBox()));
    await tester.pumpWidget(wrap(SingleChildScrollView(
      child: LocalSection(platform: TargetPlatform.windows, monitor: m, control: null, data: DataDir(tmp.path)),
    )));
    await tester.pump();
    expect(find.text('▸ 局域网地址（2 个）'), findsOneWidget);
    expect(find.text('123456789@192.168.1.5'), findsNothing);
  });

  testWidgets('with a relay and no LAN address there is no fold row', (tester) async {
    svc = FakeService('tok')..extraStatus = {'relay_addr': 'vps:22026', 'has_key': true};
    await pump(tester);
    expect(find.byKey(const Key('lan-fold')), findsNothing);
    await tester.tap(find.byKey(const Key('copy-id-0')));
    await tester.pump();
    expect(copied, ['123456789']);
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
