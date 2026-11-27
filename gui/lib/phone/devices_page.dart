/// The devices page: every device with its sessions and favourites, one column (V1b Task 7).
library;

import 'package:flutter/material.dart';

import '../ui/add_device_form.dart';
import '../ui/lamp.dart';
import '../ui/main_state.dart';
import '../ui/os_mark.dart';
import '../ui/term_restore_dialog.dart' show showTermRestore;
import '../ui/overview_model.dart';
import '../ui/session_block.dart';
import '../ui/session_model.dart';
import '../ui/tokens.dart';
import 'enter_when_open.dart';
import 'phone_nav.dart';
import 'widgets.dart';

class DeviceList extends StatefulWidget {
  const DeviceList({super.key, required this.state, required this.nav});
  final MainState state;
  final PhoneNav nav;

  @override
  State<DeviceList> createState() => _DeviceListState();
}

class _DeviceListState extends State<DeviceList> {
  bool _adding = false;
  late EnterWhenOpen _enter = EnterWhenOpen(widget.state, widget.nav);

  @override
  void didUpdateWidget(DeviceList old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state || old.nav != widget.nav) {
      _enter.dispose();
      _enter = EnterWhenOpen(widget.state, widget.nav);
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  void _tap(SessionEntry e) {
    if (e.sid == null && e.standby != null) {
      _enter.arm(device: e.id, key: e.key, stopped: e.standby == Standby.stopped);
    } else {
      _enter.cancel();
      widget.nav.enter(e.key);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final t = RappTokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final cols = deviceColumns(
          hosts: state.hub?.hosts ?? const [],
          probes: state.probes,
          entries: state.listed,
          name: state.deviceName,
          localVersion: state.hub?.version,
          localOs: state.localOs,
        ).where((c) => c.id != null);
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            for (final c in cols) ...[
              Container(
                constraints: const BoxConstraints(minHeight: phoneTap),
                child: Row(children: [
                  OsMark(c.os, key: Key('phone-os-${c.id}')),
                  const SizedBox(width: 6),
                  StatusLamp(c.lamp),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(c.name,
                        style: style?.copyWith(color: c.offline ? t.muted : t.text, fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
              for (final e in c.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: phoneTap),
                    child: SessionBlock(state: state, entry: e, onTap: () => _tap(e), grow: true),
                  ),
                ),
              for (final f in state.idleFavorites.where((f) => f.device == c.id))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: phoneTap),
                    child: FavoriteBlock(
                      favorite: f,
                      label: state.labelOf(f),
                      verb: state.favoriteVerb(f),
                      onTap: state.hubUsable && !c.offline ? () => state.favoriteVerb(f) == '恢复'
                          ? showTermRestore(context, state, f.device)
                          : state.openFavorite(f)
                      : null,
                    ),
                  ),
                ),
            ],
            PhoneButton(label: '添加设备', onPressed: state.hub == null ? null : () => setState(() => _adding = !_adding)),
            if (_adding && state.hub != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: AddDeviceForm(
                  hub: state.hub!,
                  enabled: state.hubUsable,
                  relaySet: state.relaySet,
                  onAdded: (id) {
                    setState(() => _adding = false);
                    state.selectDevice(id);
                    state.probe(id);
                  },
                ),
              ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }
}

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key, required this.state, required this.nav});
  final MainState state;
  final PhoneNav nav;

  @override
  Widget build(BuildContext context) =>
      PhonePage(title: '设备', onBack: nav.home, child: DeviceList(state: state, nav: nav));
}
