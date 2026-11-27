// 本机列「连上的服务」: rapp's own services this device uses — the 中心服务 and the LLM 网关 — each with a lamp and
// a short status (overview-local-services spec §2.1). Read-only: settings live in 全局设置 / 本机页 / LLM 接入点.
import 'dart:async';

import 'package:flutter/material.dart';

import '../llm_api.dart';
import '../state/service_switch.dart';
import '../state/state_sync.dart' show StateStatus, StateSync;
import 'lamp.dart';
import 'tokens.dart';

class LocalServices extends StatefulWidget {
  const LocalServices({
    super.key,
    this.sync,
    required this.llm,
    required this.llmApi,
    this.hostApi,
    this.localId,
    required this.nameOf,
    this.every = const Duration(seconds: 60),
  });

  /// The center link; null → no 中心服务 row.
  final StateSync? sync;
  final LlmEndpoint llm;
  final LlmApi llmApi;

  /// Says which device runs the center; null → the row shows the address only.
  final ServiceSwitchApi? hostApi;

  /// This device's id, written 本机.
  final String? localId;
  final String Function(String id) nameOf;

  /// How often the gateway is probed while shown.
  final Duration every;

  @override
  State<LocalServices> createState() => _LocalServicesState();
}

class _LocalServicesState extends State<LocalServices> {
  Timer? _timer;
  LlmProbe? _probe;

  /// Bumped by every probe and endpoint change; an older answer is dropped.
  int _probes = 0;

  String? _host;

  /// The center url [_host] was asked for; asked again when connected at a new url.
  Uri? _hostFor;
  int _hosts = 0;

  @override
  void initState() {
    super.initState();
    widget.sync?.addListener(_onSync);
    _lookHost();
    _startProbing();
  }

  @override
  void didUpdateWidget(LocalServices old) {
    super.didUpdateWidget(old);
    if (old.sync != widget.sync) {
      old.sync?.removeListener(_onSync);
      widget.sync?.addListener(_onSync);
      _hostFor = null;
      _host = null;
    }
    if (old.hostApi != widget.hostApi) _hostFor = null;
    _lookHost();
    if (old.llm != widget.llm || old.llmApi != widget.llmApi) {
      _probe = null;
      _startProbing();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.sync?.removeListener(_onSync);
    super.dispose();
  }

  void _startProbing() {
    _timer?.cancel();
    _timer = null;
    _probes++;
    if (!widget.llm.configured) return;
    _probeNow();
    _timer = Timer.periodic(widget.every, (_) => _probeNow());
  }

  Future<void> _probeNow() async {
    final n = ++_probes;
    final r = await widget.llmApi.probe(widget.llm);
    if (!mounted || n != _probes) return;
    setState(() => _probe = r);
  }

  /// The sync changed: maybe ask where the center is, and repaint.
  void _onSync() {
    _lookHost();
    if (mounted) setState(() {});
  }

  /// Asks [LocalServices.hostApi] which device runs the center, once per url it connects at.
  void _lookHost() {
    final s = widget.sync, api = widget.hostApi;
    final url = s?.status == StateStatus.connected ? s?.url : null;
    if (url == null || api == null || url == _hostFor) return;
    _hostFor = url;
    _host = null;
    final n = ++_hosts;
    api.stateHost().then<String?>((h) => h, onError: (_) => null).then((h) {
      if (!mounted || n != _hosts) return;
      setState(() => _host = h);
    });
  }

  (Lamp, String) _center(StateSync s) => switch (s.status) {
    StateStatus.connected => (Lamp.active, _where(s.url)),
    StateStatus.connecting => (Lamp.connecting, '连接中…'),
    StateStatus.none => (Lamp.offline, '没找到'),
    StateStatus.off => (Lamp.offline, '已关'),
    StateStatus.unreachable => (Lamp.disconnected, '连不上'),
  };

  String _where(Uri? url) {
    if (url == null) return '';
    final h = _host;
    if (h == null) return '${url.host}:${url.port}';
    return '${h == widget.localId ? '本机' : widget.nameOf(h)} · :${url.port}';
  }

  (Lamp, String) _llm() {
    final e = widget.llm;
    if (!e.configured) return (Lamp.offline, '没设置');
    final base = e.base!;
    final where = Uri.tryParse(base)?.authority ?? base;
    return switch (_probe) {
      null => (Lamp.connecting, where),
      LlmProbeOk() => (Lamp.active, where),
      LlmProbeFailed(:final line) => (Lamp.disconnected, line),
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    Widget row(String key, String name, (Lamp, String) v) => Padding(
      key: Key('local-service-$key'),
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        StatusLamp(v.$1),
        const SizedBox(width: 6),
        Text(name, style: small?.copyWith(color: t.text)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(v.$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: small?.copyWith(color: t.muted)),
        ),
      ]),
    );
    final s = widget.sync;
    return Column(key: const Key('local-services'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 2),
        child: Text('连上的服务', style: small?.copyWith(color: t.muted, letterSpacing: t.labelSpacing * t.textSize)),
      ),
      if (s != null) row('center', '中心服务', _center(s)),
      row('llm', 'LLM 网关', _llm()),
    ]);
  }
}
