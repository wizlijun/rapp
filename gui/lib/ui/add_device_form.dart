// Add-device form: ID@IP plus password, with the error inline.
import 'package:flutter/material.dart';

import '../hub_client.dart';
import 'controls.dart';
import 'tokens.dart';

class AddDeviceForm extends StatefulWidget {
  const AddDeviceForm({
    super.key,
    required this.hub,
    required this.onAdded,
    this.enabled = true,
  });
  final HubClient hub;
  final ValueChanged<String> onAdded;
  final bool enabled;

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
      _error = '$e';
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
          decoration: const InputDecoration(labelText: '对方的 ID@IP', isDense: true),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('add-password'),
          controller: _pw,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(labelText: '密码', isDense: true),
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
