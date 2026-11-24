// 接入引导 (iOS, spec §6): where the overview stands until a relay and key are set; also 本机's 修改接入.
import 'package:flutter/material.dart';

import '../hub_client.dart';
import 'lifecycle.dart' show disconnectWord;
import 'secure_text_field.dart';
import 'tokens.dart';
import 'controls.dart';

/// The page's frame: a narrow column in the middle of the stage.
Widget _frame(BuildContext context, List<Widget> children) {
  final t = RappTokens.of(context);
  return Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('rApp', textAlign: TextAlign.center, style: TextStyle(color: t.text, fontSize: 28, fontWeight: FontWeight.w600)),
          const SizedBox(height: 24),
          ...children,
        ]),
      ),
    ),
  );
}

class AccessSetup extends StatefulWidget {
  const AccessSetup({super.key, required this.hub, required this.onDone});
  final HubClient hub;

  /// Called once the hub saved both; not on a refusal.
  final ValueChanged<HubAccess> onDone;

  @override
  State<AccessSetup> createState() => _AccessSetupState();
}

class _AccessSetupState extends State<AccessSetup> {
  late final _relay = TextEditingController(text: widget.hub.lastAccess?.relay ?? '');
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _relay.addListener(_changed);
    _key.addListener(_changed);
  }

  @override
  void dispose() {
    _relay.dispose();
    _key.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  bool get _ready => !_busy && _relay.text.trim().isNotEmpty && _key.text.trim().isNotEmpty;

  Future<void> _go() async {
    if (!_ready) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final a = await widget.hub.setAccess(_relay.text.trim(), _key.text.trim());
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onDone(a);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = disconnectWord('$e');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final warn = Theme.of(context).colorScheme.error;
    return _frame(context, [
      TextField(
        key: const Key('access-relay'),
        controller: _relay,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(labelText: '接入点'),
      ),
      const SizedBox(height: 12),
      SecureTextField(
        key: const Key('access-key'),
        controller: _key,
        decoration: const InputDecoration(labelText: 'key'),
        onSubmitted: (_) => _go(),
      ),
      const SizedBox(height: 20),
      Align(
        child: RappButton.primary(
          key: const Key('access-go'),
          label: '接入',
          onPressed: _ready ? _go : null,
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_error!, key: const Key('access-error'), textAlign: TextAlign.center, style: TextStyle(color: warn)),
        ),
    ]);
  }
}

/// Before the hub starts (iOS): the system says this app has no network yet (the 无线数据 prompt). 设置 opens
/// the app's page in Settings; the boot tries again when the network changes or the app comes back.
class AccessNotice extends StatelessWidget {
  const AccessNotice({super.key, required this.onSettings});
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return _frame(context, [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Flexible(child: Text('没有网络权限', style: TextStyle(color: t.text))),
        const SizedBox(width: 12),
        RappButton.secondary(
          key: const Key('access-settings'),
          label: '设置',
          onPressed: onSettings,
        ),
      ]),
    ]);
  }
}
