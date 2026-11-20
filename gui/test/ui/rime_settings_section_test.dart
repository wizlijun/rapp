import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/rime_glue.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/pages/rime_settings_section.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/side_panel.dart';
import 'package:rapp_rime/rapp_rime.dart';

import '../fakes.dart';
import 'helpers.dart';

void main() {
  const channel = MethodChannel('rapp/rime-settings-test');
  late Directory tmp;
  late List<MethodCall> calls;
  late MainState st;
  late RappRime rime;
  late RimeGlue glue;
  var ready = false;

  // The platform override must be unset before the binding checks its invariants.
  void rimeTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await body(tester);
        } finally {
          glue.dispose();
          rime.dispose();
          st.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rime_settings_test');
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
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
    tmp.deleteSync(recursive: true);
  });

  void make({bool enabled = true}) {
    st = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(rimeEnabled: enabled));
    rime = RappRime(channel);
    glue = RimeGlue(st, rime: rime);
  }

  Map<String, dynamic> saved() =>
      jsonDecode(File('${st.data.prefsDir()}/gui.json').readAsStringSync()) as Map<String, dynamic>;

  Future<void> pushStatus(Map<String, Object?> s) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall('status', s)),
        (_) {},
      );

  Future<void> pumpBlock(WidgetTester tester) async {
    await tester.pumpWidget(wrap(SizedBox(width: 400, child: RimeSettingsSection(glue: glue))));
    await tester.pump();
  }

  group('全局设置', () {
    Future<void> pumpPanel(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      st.togglePanel();
      await tester.pumpWidget(wrap(SidePanel(
        state: st,
        devicesTab: const SizedBox(),
        settings: RimeSettingsSection(glue: glue),
      )));
      await tester.pump();
    }

    testWidgets('no switch off iOS', (tester) async {
      make();
      try {
        await pumpPanel(tester);
        expect(find.byKey(const Key('rime-switch')), findsNothing);
      } finally {
        glue.dispose();
        rime.dispose();
        st.dispose();
      }
    });

    rimeTest('on by default; the switch saves, hides the rows and turns the engine off', (tester) async {
      make();
      await pumpPanel(tester);
      expect(find.text('实体键盘用内置输入法'), findsOneWidget);
      expect(find.byKey(const Key('rime-redeploy')), findsOneWidget);
      expect(find.byKey(const Key('rime-dictionary')), findsOneWidget);
      expect(rime.enabled, isTrue);
      await tester.tap(find.byKey(const Key('rime-switch')));
      await tester.pump();
      expect(st.prefs.rimeEnabled, isFalse);
      expect(saved()['rime_enabled'], false);
      expect(rime.enabled, isFalse);
      expect(find.byKey(const Key('rime-redeploy')), findsNothing);
      expect(find.byKey(const Key('rime-dictionary')), findsNothing);
      expect(calls.where((c) => c.method == 'configure').last.arguments, {'enabled': false, 'dictionary': 'bundled'});
      await tester.tap(find.byKey(const Key('rime-switch')));
      await tester.pump();
      expect(rime.enabled, isTrue);
      expect(find.byKey(const Key('rime-redeploy')), findsOneWidget);
    });
  });

  rimeTest('我的目录 is not choosable until the folder is ready, and says why', (tester) async {
    make();
    await pumpBlock(tester);
    expect(find.text(rimeFolderHint), findsOneWidget);
    await tester.tap(find.text('我的目录'));
    await tester.pump();
    expect(st.prefs.rimeDictionary, 'bundled');
    await tester.tap(find.text('自带雾凇'));
    await tester.pump();
    expect(st.prefs.rimeDictionary, 'bundled');
  });

  rimeTest('back from the Files app, 我的目录 becomes choosable once the folder is there', (tester) async {
    make();
    await pumpBlock(tester);
    expect(find.text(rimeFolderHint), findsOneWidget);
    ready = true; // the user put the folder in Files, then came back
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.text(rimeFolderHint), findsOneWidget, reason: 'asked again only on resume');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(find.text(rimeFolderHint), findsNothing);
    await tester.tap(find.text('我的目录'));
    await tester.pump();
    expect(st.prefs.rimeDictionary, 'user');
  });

  rimeTest('重新部署 asks for the folder again', (tester) async {
    make();
    await pumpBlock(tester);
    expect(find.text(rimeFolderHint), findsOneWidget);
    ready = true;
    final before = calls.where((c) => c.method == 'userFolder').length;
    await tester.tap(find.byKey(const Key('rime-redeploy')));
    await tester.pump();
    await tester.pump();
    expect(calls.where((c) => c.method == 'userFolder').length, before + 1);
    expect(find.text(rimeFolderHint), findsNothing);
  });

  rimeTest('我的目录 is choosable when ready and saved; the status row follows the engine', (tester) async {
    ready = true;
    make();
    await pumpBlock(tester);
    expect(find.text(rimeFolderHint), findsNothing);
    await tester.tap(find.text('我的目录'));
    await tester.pump();
    expect(st.prefs.rimeDictionary, 'user');
    expect(saved()['rime_dictionary'], 'user');
    expect(calls.where((c) => c.method == 'configure').last.arguments, {'enabled': true, 'dictionary': 'user'});
    expect(find.text('就绪'), findsNothing);
    await pushStatus({'state': 'starting'});
    await tester.pump();
    expect(find.text('部署中…'), findsOneWidget);
    await pushStatus({'state': 'error', 'message': '没有 default.yaml'});
    await tester.pump();
    expect(find.text('出错：没有 default.yaml'), findsOneWidget);
    await tester.tap(find.byKey(const Key('rime-redeploy')));
    await tester.pump();
    expect(calls.map((c) => c.method), contains('redeploy'));
  });

  rimeTest('nothing shows while the switch is off', (tester) async {
    make(enabled: false);
    await pumpBlock(tester);
    expect(find.byKey(const Key('rime-dictionary')), findsNothing);
    expect(calls.where((c) => c.method == 'userFolder'), isEmpty);
  });
}
