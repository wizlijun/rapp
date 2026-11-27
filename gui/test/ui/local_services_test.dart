// 本机列「连上的服务」: the 中心服务 and LLM 网关 rows (overview-local-services spec §2.1).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/llm_api.dart';
import 'package:rapp/state/service_switch.dart';
import 'package:rapp/state/state_sync.dart';
import 'package:rapp/ui/lamp.dart';
import 'package:rapp/ui/local_services.dart';

import '../fakes.dart';
import 'helpers.dart';

class _FakeLlm extends LlmApi {
  final probed = <LlmEndpoint>[];
  final answers = <Completer<LlmProbe>>[];

  @override
  Future<LlmProbe> probe(LlmEndpoint e) {
    probed.add(e);
    final c = Completer<LlmProbe>();
    answers.add(c);
    return c.future;
  }
}

class _FakeHost implements ServiceSwitchApi {
  _FakeHost(this.host, {this.fails = false});
  final String? host;
  final bool fails;

  @override
  Future<String?> stateHost() async {
    if (fails) throw Exception('no service');
    return host;
  }

  @override
  Future<Map<String, Object?>> stateService({String? to, bool? on}) async => const {};
}

const _llm = LlmEndpoint(url: 'http://localhost:28001', key: 'k');

void main() {
  late Directory tmp;
  late FakeStateSync sync;
  late _FakeLlm api;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('local-services');
    sync = FakeStateSync(tmp.path);
    api = _FakeLlm();
  });

  tearDown(() {
    sync.dispose();
    tmp.deleteSync(recursive: true);
  });

  Widget build({
    StateSync? withSync,
    bool noSync = false,
    LlmEndpoint llm = const LlmEndpoint(),
    ServiceSwitchApi? host,
    String Function(String)? nameOf,
  }) => wrap(SizedBox(
    width: 220,
    child: LocalServices(
      sync: noSync ? null : (withSync ?? sync),
      llm: llm,
      llmApi: api,
      hostApi: host,
      localId: '111',
      nameOf: nameOf ?? (id) => 'Mac mini',
    ),
  ));

  Finder row(String k) => find.byKey(Key('local-service-$k'));
  Lamp lampOf(String k) =>
      (find.descendant(of: row(k), matching: find.byType(StatusLamp)).evaluate().single.widget as StatusLamp).kind;
  Finder textIn(String k, String s) => find.descendant(of: row(k), matching: find.text(s));

  void connect([String url = 'http://127.0.0.1:28003']) {
    sync
      ..status = StateStatus.connected
      ..url = Uri.parse(url)
      ..notifyListeners();
  }

  testWidgets('center connected on this device reads 本机 · :28003', (tester) async {
    connect();
    await tester.pumpWidget(build(host: _FakeHost('111')));
    await tester.pump();
    expect(find.byKey(const Key('local-services')), findsOneWidget);
    expect(find.text('连上的服务'), findsOneWidget);
    expect(textIn('center', '中心服务'), findsOneWidget);
    expect(textIn('center', '本机 · :28003'), findsOneWidget);
    expect(lampOf('center'), Lamp.active);
  });

  testWidgets('center on another device names it', (tester) async {
    connect();
    await tester.pumpWidget(build(host: _FakeHost('222')));
    await tester.pump();
    expect(textIn('center', 'Mac mini · :28003'), findsOneWidget);
  });

  testWidgets('host lookup failing falls back to the address', (tester) async {
    connect();
    await tester.pumpWidget(build(host: _FakeHost(null, fails: true)));
    await tester.pump();
    expect(textIn('center', '127.0.0.1:28003'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the host is asked again when the address changes', (tester) async {
    connect();
    await tester.pumpWidget(build(host: _FakeHost('111')));
    await tester.pump();
    connect('http://127.0.0.1:28009');
    await tester.pump();
    await tester.pump();
    expect(textIn('center', '本机 · :28009'), findsOneWidget);
  });

  testWidgets('center states map to their words', (tester) async {
    await tester.pumpWidget(build());
    for (final (st, word, lamp) in [
      (StateStatus.connecting, '连接中…', Lamp.connecting),
      (StateStatus.none, '没找到', Lamp.offline),
      (StateStatus.off, '已关', Lamp.offline),
      (StateStatus.unreachable, '连不上', Lamp.disconnected),
    ]) {
      sync
        ..status = st
        ..notifyListeners();
      await tester.pump();
      expect(textIn('center', word), findsOneWidget, reason: '$st');
      expect(lampOf('center'), lamp, reason: '$st');
    }
  });

  testWidgets('no sync, no center row', (tester) async {
    await tester.pumpWidget(build(noSync: true));
    expect(row('center'), findsNothing);
    expect(row('llm'), findsOneWidget);
  });

  testWidgets('llm not configured: 没设置, never probed', (tester) async {
    await tester.pumpWidget(build());
    expect(textIn('llm', 'LLM 网关'), findsOneWidget);
    expect(textIn('llm', '没设置'), findsOneWidget);
    expect(lampOf('llm'), Lamp.offline);
    await tester.pump(const Duration(seconds: 61));
    expect(api.probed, isEmpty);
  });

  testWidgets('llm probes on show and every 60 s', (tester) async {
    await tester.pumpWidget(build(llm: _llm));
    expect(api.probed, hasLength(1));
    expect(textIn('llm', 'localhost:28001'), findsOneWidget);
    expect(lampOf('llm'), Lamp.connecting);
    api.answers[0].complete(const LlmProbeOk([], Duration.zero));
    await tester.pump();
    expect(lampOf('llm'), Lamp.active);
    expect(textIn('llm', 'localhost:28001'), findsOneWidget);
    await tester.pump(const Duration(seconds: 60));
    expect(api.probed, hasLength(2));
    api.answers[1].complete(const LlmProbeFailed('key 不对'));
    // A probe the timer started answers after that frame's build; the next frame shows it.
    await tester.pump();
    await tester.pump();
    expect(textIn('llm', 'key 不对'), findsOneWidget);
    expect(lampOf('llm'), Lamp.disconnected);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a probe answering after unmount is dropped', (tester) async {
    await tester.pumpWidget(build(llm: _llm));
    await tester.pumpWidget(const SizedBox());
    api.answers[0].complete(const LlmProbeOk([], Duration.zero));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 120));
    expect(api.probed, hasLength(1));
  });

  testWidgets('a new endpoint re-probes and drops the old answer', (tester) async {
    await tester.pumpWidget(build(llm: _llm));
    await tester.pumpWidget(build(llm: const LlmEndpoint(url: 'http://localhost:28002', key: 'k')));
    expect(api.probed, hasLength(2));
    api.answers[1].complete(const LlmProbeFailed('连不上：x'));
    await tester.pump();
    api.answers[0].complete(const LlmProbeOk([], Duration.zero));
    await tester.pump();
    expect(textIn('llm', '连不上：x'), findsOneWidget);
    expect(lampOf('llm'), Lamp.disconnected);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('long text ellipsizes', (tester) async {
    connect();
    await tester.pumpWidget(build(llm: _llm, host: _FakeHost('222'), nameOf: (_) => '名' * 60));
    api.answers[0].complete(LlmProbeFailed('长' * 120));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rows have no tap action', (tester) async {
    await tester.pumpWidget(build());
    for (final k in ['center', 'llm']) {
      expect(find.descendant(of: row(k), matching: find.byType(InkWell)), findsNothing);
      expect(find.descendant(of: row(k), matching: find.byType(GestureDetector)), findsNothing);
    }
  });
}
