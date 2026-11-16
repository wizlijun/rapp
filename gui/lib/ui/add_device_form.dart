// Add-device form: ID@IP plus password, with the error inline.
import 'dart:io' show InternetAddress;

import 'package:flutter/material.dart';

import '../hub_client.dart';
import 'controls.dart';
import 'lifecycle.dart' show connectionFailureHint;
import 'secure_text_field.dart';
import 'tokens.dart';

class AddDeviceForm extends StatefulWidget {
  const AddDeviceForm({
    super.key,
    required this.hub,
    required this.onAdded,
    this.enabled = true,
    this.relaySet = false,
  });
  final HubClient hub;
  final ValueChanged<String> onAdded;
  final bool enabled;

  /// This machine has a relay: add by bare ID, and the password may stay empty (a key does the work).
  final bool relaySet;

  @override
  State<AddDeviceForm> createState() => _AddDeviceFormState();
}

class _AddDeviceFormState extends State<AddDeviceForm> {
  final _id = TextEditingController();
  final _pw = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _id.dispose();
    _pw.dispose();
    super.dispose();
  }

  /// Match the hub's ID@IP[:port] syntax; a bare IPv6 address uses the default.
  /// This is the remote peer's UDP port, never the local service IPC port.
  int? _peerPort(String host) {
    final at = host.indexOf('@');
    if (at < 0) return null;
    final address = host.substring(at + 1);
    if (InternetAddress.tryParse(address) != null) return 22028;
    final match = RegExp(r'^(?:\[([^\]]+)\]|([^:]+)):([0-9]+)$').firstMatch(address);
    if (match == null || InternetAddress.tryParse(match.group(1) ?? match.group(2)!) == null) return null;
    final port = int.tryParse(match.group(3)!);
    return port != null && port > 0 && port <= 65535 ? port : null;
  }

  Future<void> _add() async {
    final id = _id.text.trim();
    if (id.isEmpty || _busy || !widget.enabled) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final host = await widget.hub.addHost(id, _pw.text);
      if (!mounted) return;
      _id.clear();
      _pw.clear();
      widget.onAdded(host.id);
    } catch (e) {
      _error = connectionFailureHint('$e', peerPort: _peerPort(id), relayed: !id.contains('@') && widget.relaySet);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('add-id'),
          controller: _id,
          decoration: InputDecoration(labelText: widget.relaySet ? '对方的 ID' : '对方的 ID@IP', isDense: true),
        ),
        const SizedBox(height: 8),
        SecureTextField(
          key: const Key('add-password'),
          controller: _pw,
          decoration: InputDecoration(
              labelText: '密码', hintText: widget.relaySet ? '有 key 时不用填' : null, isDense: true),
          onSubmitted: (_) => _add(),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: RappButton.primary(
            key: const Key('add-button'),
            label: '添加设备',
            onPressed: (_busy || !widget.enabled) ? null : _add,
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: TextStyle(color: t.accent)),
          ),
      ],
    );
  }
}
