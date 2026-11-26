// The 状态服务 switch on a device page: turns that device's rapp-state service on or off.
import 'dart:async';

import 'package:flutter/material.dart';

import '../service_client.dart' show ServiceException;
import '../shares.dart';
import '../state/service_switch.dart';
import 'controls.dart';
import 'tokens.dart';

class StateServiceRow extends StatefulWidget {
  const StateServiceRow({super.key, required this.api, this.to, required this.nameOf, this.localId});
  final ServiceSwitchApi api;

  /// The device to ask; null is this one.
  final String? to;
  final String Function(String id) nameOf;

  /// This app's own device, written 本机 when it hosts the service.
  final String? localId;

  @override
  State<StateServiceRow> createState() => _StateServiceRowState();
}

class _StateServiceRowState extends State<StateServiceRow> {
  Map<String, Object?>? _reply;
  String? _host;
  bool _failed = false;
  bool _busy = false;
  String? _error;
  Timer? _retry;

  /// The device is too old to have the switch, or will never have it here: asking again would not change that.
  bool _old = false;

  /// Bumped by every load; an answer to an older one is dropped.
  int _loads = 0;

  static const _permanent = ['unknown op', 'old version', 'not supported', 'host only', 'unknown service'];

  static const _retryEvery = Duration(seconds: 10);

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StateServiceRow old) {
    super.didUpdateWidget(old);
    if (old.to != widget.to || old.api != widget.api || old.localId != widget.localId) {
      final other = old.to != widget.to || old.api != widget.api;
      _retry?.cancel();
      _old = false;
      _failed = false;
      if (other) {
        _reply = null;
        _error = null;
        _busy = false;
      }
      _load();
    }
  }

  Future<void> _load() async {
    _retry?.cancel();
    _retry = null;
    final api = widget.api, to = widget.to;
    final load = ++_loads;
    bool stale() => !mounted || load != _loads || widget.api != api || widget.to != to;
    api.stateHost().then<String?>((h) => h, onError: (_) => null).then((h) {
      if (stale()) return;
      setState(() => _host = h);
    });
    try {
      final r = await api.stateService(to: to);
      if (stale()) return;
      setState(() {
        _reply = r;
        _failed = false;
      });
    } catch (e) {
      if (stale()) return;
      final why = e is ServiceException ? e.message : '$e';
      _old = _permanent.any(why.contains);
      setState(() {
        _failed = true;
        _reply = null;
      });
      _retry?.cancel();
      _retry = _old ? null : Timer(_retryEvery, _load);
    }
  }

  Future<void> _set(bool v) async {
    final api = widget.api, to = widget.to;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await api.stateService(to: to, on: v);
      if (!mounted || widget.api != api || widget.to != to) return;
      setState(() => _reply = r);
    } catch (e) {
      if (!mounted || widget.api != api || widget.to != to) return;
      setState(() => _error = '${v ? '没开成' : '没关成'}：${shareErrorText(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // Where the one in the network sits may have changed.
    api.stateHost().then<String?>((h) => h, onError: (_) => null).then((h) {
      if (mounted && widget.api == api && widget.to == to) setState(() => _host = h);
    });
  }

  String? _status(Map<String, Object?> r) {
    if (r['on'] != true) return null;
    final err = r['error'];
    if (err is String && err.isNotEmpty) return err;
    if (r['running'] == true && r['port'] != null) return '运行中，端口 ${r['port']}';
    return '启动中';
  }

  @override
  Widget build(BuildContext context) {
    final r = _reply;
    if (_failed || r == null) return const SizedBox.shrink();
    final t = RappTokens.of(context);
    final status = _status(r);
    final target = widget.to ?? widget.localId;
    final host = _host;
    final elsewhere = host != null && host != target;
    final lines = [
      ?status,
      if (elsewhere) '已经有一个在 ${host == widget.localId ? '本机' : widget.nameOf(host)} 上',
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RappSwitchRow(
        label: '状态服务',
        value: r['on'] == true,
        onChanged: _busy ? null : _set,
      ),
      for (final l in lines)
        Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Text(l, style: TextStyle(color: t.muted))),
      if (_error case final e?)
        Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Text(e, style: TextStyle(color: t.accent))),
    ]);
  }
}
