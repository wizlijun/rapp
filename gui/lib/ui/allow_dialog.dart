// "谁能用这个端口": which devices may use one shared port.
import 'package:flutter/material.dart';

import '../shares.dart';
import 'controls.dart';
import 'tokens.dart';

/// Asks who may use a port. Null: cancelled. `[]`: every device. Otherwise the ticked
/// fingerprints, in the order of [candidates], then those of [current] that are not among them.
Future<List<String>?> showAllowDialog(
  BuildContext context, {
  required List<Device> candidates,
  required List<Device> current,
}) => showDialog<List<String>>(
  context: context,
  builder: (_) => AllowDialog(candidates: candidates, current: current),
);

class AllowDialog extends StatefulWidget {
  const AllowDialog({super.key, required this.candidates, required this.current});
  final List<Device> candidates;
  final List<Device> current;

  @override
  State<AllowDialog> createState() => _AllowDialogState();
}

class _AllowDialogState extends State<AllowDialog> {
  late bool _all = widget.current.isEmpty;
  late final Set<String> _ticked = {for (final d in widget.current) d.fp};

  List<Device> get _extras {
    final known = {for (final d in widget.candidates) d.fp};
    return [for (final d in widget.current) if (!known.contains(d.fp)) d];
  }

  List<String> get _result => [
        for (final d in [...widget.candidates, ..._extras])
          if (_ticked.contains(d.fp)) d.fp,
      ];

  Widget _choice(RappTokens t, Key key, String label, bool selected, VoidCallback onTap) => InkWell(
        key: key,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18, color: selected ? t.accent : t.muted),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: t.text)),
          ]),
        ),
      );

  Widget _device(RappTokens t, Device d) => CheckboxListTile(
        key: Key('allow-device-${d.fp}'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(d.name, style: TextStyle(color: _all ? t.muted : t.text)),
        value: _ticked.contains(d.fp),
        onChanged: _all ? null : (v) => setState(() => v == true ? _ticked.add(d.fp) : _ticked.remove(d.fp)),
      );

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final canSave = _all || _ticked.isNotEmpty;
    return AlertDialog(
      title: const Text('谁能用这个端口'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _choice(t, const Key('allow-all'), '所有设备', _all, () => setState(() => _all = true)),
              _choice(t, const Key('allow-some'), '只给勾选的设备', !_all, () => setState(() => _all = false)),
              const SizedBox(height: 4),
              for (final d in [...widget.candidates, ..._extras]) _device(t, d),
              if (widget.candidates.length <= 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('别的设备连过这台以后才能选', style: TextStyle(color: t.muted)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        RappButton.secondary(key: const Key('allow-cancel'), label: '取消', onPressed: () => Navigator.pop(context)),
        RappButton.secondary(
          key: const Key('allow-save'),
          label: '保存',
          onPressed: canSave ? () => Navigator.pop(context, _all ? <String>[] : _result) : null,
        ),
      ],
    );
  }
}
