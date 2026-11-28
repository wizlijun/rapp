import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/voice_button.dart' show voiceBlank;
import 'package:rapp/embed/voice_tidy.dart' show TidyPhase;
import 'package:rapp/hub_client.dart';
import 'package:rapp/llm_api.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/phone/assistant_page.dart';
import 'package:rapp/phone/assistant_store.dart';
import 'package:rapp/phone/home_screen.dart';
import 'package:rapp/phone/phone_nav.dart';
import 'package:rapp/phone/phone_voice.dart';
import 'package:rapp/phone/sheet.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/ui/unlock.dart';

import '../embed/voice_button_test.dart' show FakeVoice;
import '../fakes.dart';

const _long = '这是一段比较长的中性测试文字';

void main() {
  late Directory tmp;
  late FakeTransport tr;
  late FakeVoice voice;
  late MainState s;
  late PhoneNav nav;
  late List<Map<String, Object?>> sent;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('assistant_test');
    sent = [];
    tr = FakeTransport();
  });
  tearDown(() {
    nav.dispose();
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> boot(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    voice = FakeVoice();
    s = MainState(
        hub: HubClient(tr),
        data: DataDir(tmp.path),
        prefs: UiPrefs(),
        port: FakeSessionPort(),
        voice: voice,
        unlockStore: UnlockStore(supported: false, memory: false),
        termPort: FakeTermSessionPort());
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    nav = PhoneNav(s, send: (t, {seq, text, enter = false, keys = const []}) async {
      sent.add({'text': text});
    });
  }

  Widget host(Widget child) => MaterialApp(
        theme: themeDataFor(RappTheme.matrix),
        home: Scaffold(resizeToAvoidBottomInset: false, body: child),
      );

  final button = find.byKey(const Key('assistant-voice'));

  Future<void> say(WidgetTester tester, String words) async {
    voice.stopResult = words;
    final g = await tester.startGesture(tester.getCenter(button));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> flush(WidgetTester tester) => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));

  test('store keeps notes on disk only', () async {
    tmp = Directory.systemTemp.createTempSync('assistant_store');
    final st = AssistantStore(tmp.path);
    await st.add('第一条');
    await st.add('第二条', project: 'p1');
    await st.add('   ');
    expect(st.notes.map((n) => n.text), ['第二条', '第一条']);
    final back = AssistantStore(tmp.path);
    expect(back.notes.map((n) => n.text), ['第二条', '第一条']);
    expect(back.notes.first.project, 'p1');
    expect(back.notes.last.project, isNull);
    expect(File('${tmp.path}/assistant.json').existsSync(), isTrue);
    expect(File('${tmp.path}/assistant.json.tmp').existsSync(), isFalse);
    await back.remove(back.notes.first.id);
    expect(AssistantStore(tmp.path).notes.map((n) => n.text), ['第一条']);
    // a damaged file is an empty list
    File('${tmp.path}/assistant.json').writeAsStringSync('{');
    expect(AssistantStore(tmp.path).notes, isEmpty);
    nav = PhoneNav(MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort()));
    s = nav.state;
  });

  test('a note with a bad project field keeps every note', () {
    tmp = Directory.systemTemp.createTempSync('assistant_store');
    File('${tmp.path}/assistant.json').writeAsStringSync(jsonEncode({
      'notes': [
        {'id': 'a', 'text': '一', 'at': 3, 'project': 'p1'},
        {'id': 'b', 'text': '二', 'at': 2, 'project': 7},
        {'id': 'c', 'text': '三', 'at': 1},
      ]
    }));
    final st = AssistantStore(tmp.path);
    expect(st.notes.map((n) => n.text), ['一', '二', '三']);
    expect(st.notes.map((n) => n.project), ['p1', null, null]);
    nav = PhoneNav(MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), port: FakeSessionPort()));
    s = nav.state;
  });

  testWidgets('home voice goes to the assistant', (tester) async {
    await boot(tester);
    await tester.pumpWidget(host(HomeScreen(state: s, nav: nav)));
    expect(tester.getSize(button).height, greaterThanOrEqualTo(64));
    expect(find.text('按住说话，跟助理说'), findsOneWidget);
    await say(tester, '记一下这个');
    await flush(tester);
    expect(nav.assistant.notes.map((n) => n.text), ['记一下这个']);
    expect(nav.assistant.notes.single.project, isNull);
    expect(sent, isEmpty);
    expect(tr.sent.where((m) => m['cmd'] != 'net' && m['cmd'] != 'hosts'), isEmpty);
    // nothing heard saves nothing
    await say(tester, '');
    expect(nav.assistant.notes.length, 1);
    expect(find.text(voiceBlank), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a long hold does not go to the tidy', (tester) async {
    await boot(tester);
    s.setLlm(const LlmEndpoint(url: 'localhost:1', key: 'k'));
    await tester.pumpWidget(host(HomeScreen(state: s, nav: nav)));
    expect(s.voiceNoTidy, contains('assistant'));
    expect(s.tidyOf('assistant').would(_long), isFalse);
    await say(tester, _long);
    await flush(tester);
    expect(s.tidyOf('assistant').phase, TidyPhase.idle);
    expect(nav.assistant.notes.map((n) => n.text), [_long]);
    // the flag follows the widget, and goes with it
    await tester.pumpWidget(host(const SizedBox()));
    expect(s.voiceNoTidy, isEmpty);
    expect(s.voiceSends, isEmpty);
  });

  testWidgets('the key without tidy:false still tidies, and a takeover keeps the flag', (tester) async {
    await boot(tester);
    s.setLlm(const LlmEndpoint(url: 'localhost:1', key: 'k'));
    Widget v(Object k, {bool tidy = true}) => PhoneVoice(
        state: s, key2: k, tidy: tidy, send: (t, o) => null, edit: (_) {}, builder: (c, h) => phoneVoiceButton(h, 'x'));
    await tester.pumpWidget(host(Column(children: [v('a'), v('assistant', tidy: false)])));
    expect(s.tidyOf('a').would(_long), isTrue);
    expect(s.tidyOf('assistant').would(_long), isFalse);
  });

  testWidgets('编辑 opens the page with the words in the input; only 存下 adds a note', (tester) async {
    await boot(tester);
    await tester.pumpWidget(host(HomeScreen(state: s, nav: nav)));
    // the home's 编辑 does just this
    nav.assistantDraft = '先写在这里';
    nav.open(PhoneView.assistant);
    expect(nav.now, PhoneView.assistant);
    expect(nav.assistant.notes, isEmpty);
    await tester.pumpWidget(host(AssistantPage(store: nav.assistant, nav: nav)));
    expect(find.widgetWithText(TextField, '先写在这里'), findsOneWidget);
    expect(nav.assistant.notes, isEmpty);
    await tester.tap(find.text('存下'));
    await tester.pump();
    await flush(tester);
    await tester.pump();
    expect(nav.assistant.notes.map((n) => n.text), ['先写在这里']);
    expect(find.text('先写在这里'), findsOneWidget); // in the list now, input cleared
  });

  testWidgets('delete and long-press copy', (tester) async {
    await boot(tester);
    String? clip;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') clip = (c.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.runAsync(() async {
      await nav.assistant.add('甲', project: 'proj');
      await nav.assistant.add('乙');
    });
    await tester.pumpWidget(host(AssistantPage(store: nav.assistant, nav: nav)));
    expect(find.text('助理还不会回答，先替你记着。'), findsOneWidget);
    expect(find.textContaining('proj'), findsOneWidget);
    expect(tester.getSize(find.byKey(Key('note-del-${nav.assistant.notes.first.id}'))).height, greaterThanOrEqualTo(56));
    await tester.longPress(find.text('甲'));
    await tester.pump();
    expect(clip, '甲');
    expect(find.text('已复制'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('已复制'), findsNothing);
    await tester.tap(find.byKey(Key('note-del-${nav.assistant.notes.last.id}')));
    await tester.pump();
    await flush(tester);
    expect(nav.assistant.notes.map((n) => n.text), ['乙']);
    expect(find.text('甲'), findsNothing);
  });

  testWidgets('sheet lists 助理 first, 12 apart', (tester) async {
    await boot(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(Builder(builder: (c) => TextButton(onPressed: () => showPhoneSheet(c, nav), child: const Text('go')))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    final ys = [for (final w in ['助理', '设备', '设置']) tester.getTopLeft(find.text(w)).dy];
    expect(ys[0] < ys[1] && ys[1] < ys[2], isTrue);
    final row = find.ancestor(of: find.text('助理'), matching: find.byType(InkWell)).first;
    expect(tester.getSize(row).height, greaterThanOrEqualTo(56));
    final r2 = find.ancestor(of: find.text('设备'), matching: find.byType(InkWell)).first;
    expect(tester.getTopLeft(r2).dy - tester.getBottomLeft(row).dy, 12);
    await tester.tap(find.text('助理'));
    await tester.pumpAndSettle();
    expect(nav.now, PhoneView.assistant);
  });

  testWidgets('no send button on the page', (tester) async {
    await boot(tester);
    await tester.runAsync(() => nav.assistant.add('甲'));
    await tester.pumpWidget(host(AssistantPage(store: nav.assistant, nav: nav)));
    expect(find.textContaining('发给'), findsNothing);
    expect(find.textContaining('终端'), findsNothing);
    expect(find.textContaining('发送'), findsNothing);
    expect(find.textContaining('安全'), findsNothing);
    expect(find.text('存下'), findsOneWidget);
    expect(sent, isEmpty);
  });
}
