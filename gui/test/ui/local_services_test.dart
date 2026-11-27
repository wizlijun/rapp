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
  String? host;
  final bool fails;
  int asked = 0;

  /// When set, the next answer waits for it.
  Completer<String?>? hold;

  @override
  Future<String?> stateHost() async {
    asked++;
    if (fails) throw Exception('no service');
    final h = hold;
    if (h != null) return h.future;
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

  testWidgets('reconnecting at the same address asks the host again', (tester) async {
    final host = _FakeHost('111');
    connect();
    await tester.pumpWidget(build(host: host));
    await tester.pump();
    expect(textIn('center', '本机 · :28003'), findsOneWidget);
    sync
      ..status = StateStatus.connecting
      ..notifyListeners();
    await tester.pump();
    // The center moved to another device but kept the same share address.
    host.host = '222';
    connect();
    await tester.pump();
    await tester.pump();
    expect(host.asked, 2);
    expect(textIn('center', 'Mac mini · :28003'), findsOneWidget);
  });

  testWidgets('a host answer from before the link dropped is not shown', (tester) async {
    final host = _FakeHost('111')..hold = Completer();
    final first = host.hold!;
    connect();
    await tester.pumpWidget(build(host: host));
    sync
      ..status = StateStatus.unreachable
      ..notifyListeners();
    await tester.pump();
    host.hold = null;
    host.host = '222';
    connect();
    await tester.pump();
    await tester.pump();
    first.complete('111');
    await tester.pump();
    expect(textIn('center', 'Mac mini · :28003'), findsOneWidget);
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

  testWidgets('long text wraps onto more lines and is shown in full', (tester) async {
    final long = '连不上：${'很长的原因' * 12}';
    await tester.pumpWidget(build(llm: _llm));
    await tester.pump();
    final oneLine = tester.getSize(row('llm')).height;
    api.answers[0].complete(LlmProbeFailed(long));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final t = tester.widget<Text>(textIn('llm', long));
    expect(t.maxLines, isNull);
    expect(t.overflow, isNot(TextOverflow.ellipsis));
    expect(tester.getSize(row('llm')).height, greaterThan(oneLine * 2));
    // The lamp stays on the first line, beside the name.
    expect(tester.getCenter(find.descendant(of: row('llm'), matching: find.byType(StatusLamp))).dy,
        lessThan(tester.getTopLeft(row('llm')).dy + oneLine));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a long device name wraps too', (tester) async {
    connect();
    await tester.pumpWidget(build(host: _FakeHost('222'), nameOf: (_) => '名' * 40));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(textIn('center', '${'名' * 40} · :28003'), findsOneWidget);
    expect(tester.widget<Text>(textIn('center', '${'名' * 40} · :28003')).maxLines, isNull);
  });

  testWidgets('rows have no tap action', (tester) async {
    await tester.pumpWidget(build());
    for (final k in ['center', 'llm']) {
      expect(find.descendant(of: row(k), matching: find.byType(InkWell)), findsNothing);
      expect(find.descendant(of: row(k), matching: find.byType(GestureDetector)), findsNothing);
    }
  });
}
