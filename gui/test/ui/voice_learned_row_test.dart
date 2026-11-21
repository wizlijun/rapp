import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/embed/tidy_diff.dart' show LearnAction;
import 'package:rapp/hub_client.dart';
import 'package:rapp/llm_api.dart';
import 'package:rapp/paths.dart';
import 'package:rapp/ui/main_state.dart';
import 'package:rapp/ui/prefs.dart';
import 'package:rapp/ui/voice_learned_row.dart';

import '../fakes.dart';
import 'helpers.dart';

class _Api extends LlmApi {
  _Api(this.entries);
  List<LearnedEntry>? entries;
  int asks = 0;
  final forgotten = <String>[];

  @override
  Future<List<LearnedEntry>?> learned(LlmEndpoint e) async {
    asks++;
    return entries;
  }

  @override
  Future<bool> forget(LlmEndpoint e, String id) async {
    forgotten.add(id);
    return true;
  }
}

void main() {
  late Directory tmp;
  late MainState s;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('voice_learned_row');
    Directory('${tmp.path}/local').createSync();
    File('${tmp.path}/local/service.json').writeAsStringSync('{"id":"dev1"}');
  });
  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<_Api> mount(WidgetTester tester, List<LearnedEntry>? entries, {bool endpoint = true}) async {
    final api = _Api(entries);
    s = MainState(hub: HubClient(FakeTransport()), data: DataDir(tmp.path), prefs: UiPrefs(), llmApi: api);
    if (endpoint) s.setLlm(const LlmEndpoint(url: 'localhost:28001', key: 'k'));
    await tester.pumpWidget(wrap(VoiceLearnedRow(state: s, style: const TextStyle(fontSize: 12))));
    return api;
  }

  const entries = [
    LearnedEntry(id: 'a', action: LearnAction.replace, observed: '拍森', output: 'Python'),
    LearnedEntry(id: 'b', action: LearnAction.preserve, observed: '黑猫瑞'),
  ];

  testWidgets('hidden when the endpoint is not set', (tester) async {
    await mount(tester, entries, endpoint: false);
    expect(find.byKey(const Key('voice-learned')), findsNothing);
  });

  testWidgets('hidden when the gateway gives null', (tester) async {
    final api = await mount(tester, null);
    expect(find.byKey(const Key('voice-learned')), findsOneWidget);
    expect(api.asks, 0);
    await tester.tap(find.byKey(const Key('voice-learned')));
    await tester.pumpAndSettle();
    expect(api.asks, 1);
    expect(find.byKey(const Key('voice-learned')), findsNothing);
  });

  testWidgets('tapping opens the list: 拍森 → Python, 不改：黑猫瑞', (tester) async {
    await mount(tester, entries);
    expect(find.text('拍森 → Python'), findsNothing);
    await tester.tap(find.byKey(const Key('voice-learned')));
    await tester.pumpAndSettle();
    expect(find.text('拍森 → Python'), findsOneWidget);
    expect(find.text('不改：黑猫瑞'), findsOneWidget);
  });

  testWidgets('delete removes the row and calls forgetLearned', (tester) async {
    final api = await mount(tester, entries);
    await tester.tap(find.byKey(const Key('voice-learned')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-learned-delete-a')));
    await tester.pumpAndSettle();
    expect(api.forgotten, ['a']);
    expect(find.byKey(const Key('voice-learned-a')), findsNothing);
    expect(find.byKey(const Key('voice-learned-b')), findsOneWidget);
  });

  testWidgets('an empty list says 还没有', (tester) async {
    await mount(tester, const []);
    await tester.tap(find.byKey(const Key('voice-learned')));
    await tester.pumpAndSettle();
    expect(find.text('还没有'), findsOneWidget);
  });
}
