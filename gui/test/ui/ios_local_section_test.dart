import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/ios_local_section.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/controls.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp_rime/rapp_rime.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  late FakeTransport t;
  late HubClient hub;
  late UiPrefs prefs;
  late Directory tmp;
  late int saved;

  setUp(() {
    t = FakeTransport();
    hub = HubClient(t);
    prefs = UiPrefs();
    tmp = Directory.systemTemp.createTempSync('rapp-ios-local');
    Directory('${tmp.path}/files/transfers').createSync(recursive: true);
    File('${tmp.path}/files/transfers/a.bin').writeAsBytesSync(List.filled(2048, 1));
    File('${tmp.path}/files/b.bin').writeAsBytesSync(List.filled(1024, 1));
    saved = 0;
    t.onSend = (cmd) {
      if (cmd['cmd'] == 'access') {
        t.emit({'event': 'access', 'relay': 'r.example:7000', 'has_key': true, 'name': 'Bruce 的 iPad', 'req': cmd['req']});
      }
    };
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(wrap(SingleChildScrollView(
      child: IosLocalSection(
        hub: hub,
        prefs: prefs,
        onPrefs: () => saved++,
        data: DataDir(tmp.path),
        version: () async => '0.13.7',
      ),
    )));
    // 数据用量 is counted on another isolate: wait (real time) until it lands.
    for (var i = 0; i < 100 && find.text('计算中…').evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  testWidgets('shows the relay, a masked key, the name, the data use and the version', (tester) async {
    await pump(tester);
    expect(find.text('接入点'), findsOneWidget);
    expect(find.text('r.example:7000'), findsOneWidget);
    expect(find.byKey(const Key('ios-key-value')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('ios-key-value'))).data, '••••••');
    expect(find.text('Bruce 的 iPad'), findsOneWidget);
    expect(find.text('3 KB'), findsOneWidget);
    expect(find.text('0.13.7'), findsOneWidget);
    expect(find.text('修改接入'), findsOneWidget);
  });

  testWidgets('显示 reveals only the last 4 of a key typed this run', (tester) async {
    t.onSend = (cmd) {
      if (cmd['cmd'] == 'access' || cmd['cmd'] == 'set_access') {
        t.emit({'event': 'access', 'relay': 'r:1', 'has_key': true, 'name': 'iPad', 'req': cmd['req']});
      }
    };
    await tester.runAsync(() => hub.setAccess('r:1', 'secretWXYZ'));
    await pump(tester);
    expect(tester.widget<Text>(find.byKey(const Key('ios-key-value'))).data, '••••••');
    expect(find.textContaining('secret'), findsNothing);
    await tester.tap(find.byKey(const Key('ios-key-reveal')));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('ios-key-value'))).data, '••••••WXYZ');
    expect(find.textContaining('secret'), findsNothing);
  });

  testWidgets('the keep-awake row is bounded to 320 wide', (tester) async {
    await pump(tester);
    expect(tester.getSize(find.ancestor(of: find.byKey(const Key('keep-awake-switch')), matching: find.byType(RappSwitchRow))).width, lessThanOrEqualTo(320));
  });

  testWidgets('the keep-awake switch flips prefs.keepAwake and saves', (tester) async {
    expect(prefs.keepAwake, isTrue);
    await pump(tester);
    expect(find.text('屏幕常亮'), findsOneWidget);
    await tester.tap(find.byKey(const Key('keep-awake-switch')));
    await tester.pump();
    expect(prefs.keepAwake, isFalse);
    expect(saved, 1);
    await tester.tap(find.byKey(const Key('keep-awake-switch')));
    await tester.pump();
    expect(prefs.keepAwake, isTrue);
    expect(saved, 2);
  });

  group('built-in IME rows', () {
    const channel = MethodChannel('rapp/rime');
    late List<MethodCall> calls;

    // The platform override must be unset before the binding checks its invariants.
    void rimeTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
          try {
            await body(tester);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
    var ready = false;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      calls = [];
      ready = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'userFolder') return {'path': '/x/Rime', 'ready': ready};
        return null;
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      RappRime.instance.configure(
          enabled: false, builtin: true, dictionary: RimeDictionary.bundled, onBuiltin: (_) {});
    });

    rimeTest('off by default; the switch saves, shows the rows and configures', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('rime-switch')), findsOneWidget);
      expect(find.byKey(const Key('rime-redeploy')), findsNothing);
      await tester.tap(find.byKey(const Key('rime-switch')));
      await tester.pump();
      expect(prefs.rimeEnabled, isTrue);
      expect(saved, 1);
      expect(find.byKey(const Key('rime-redeploy')), findsOneWidget);
      expect(find.byKey(const Key('rime-dictionary')), findsOneWidget);
      expect(calls.where((c) => c.method == 'configure').single.arguments, {'enabled': true, 'dictionary': 'bundled'});
    });

    rimeTest('我的目录 is not choosable until the folder is ready, and says why', (tester) async {
      prefs.rimeEnabled = true;
      await pump(tester);
      await tester.pump();
      expect(find.text('把 Rime 目录放进「文件」→ rapp → Rime 后可选'), findsOneWidget);
      await tester.tap(find.text('我的目录'));
      await tester.pump();
      expect(prefs.rimeDictionary, 'bundled');
      await tester.tap(find.text('自带雾凇'));
      await tester.pump();
      expect(prefs.rimeDictionary, 'bundled');
    });

    rimeTest('我的目录 is choosable when ready; the status row follows the engine', (tester) async {
      ready = true;
      prefs.rimeEnabled = true;
      await pump(tester);
      await tester.pump();
      expect(find.text('把 Rime 目录放进「文件」→ rapp → Rime 后可选'), findsNothing);
      await tester.tap(find.text('我的目录'));
      await tester.pump();
      expect(prefs.rimeDictionary, 'user');
      expect(saved, 1);
      expect(find.text('就绪'), findsNothing);
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'rapp/rime',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('status', {'state': 'starting'})),
        (_) {},
      );
      await tester.pump();
      expect(find.text('部署中…'), findsOneWidget);
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'rapp/rime',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('status', {'state': 'error', 'message': '没有 default.yaml'})),
        (_) {},
      );
      await tester.pump();
      expect(find.text('出错：没有 default.yaml'), findsOneWidget);
      await tester.tap(find.byKey(const Key('rime-redeploy')));
      await tester.pump();
      expect(calls.map((c) => c.method), contains('redeploy'));
    });
  });
}
