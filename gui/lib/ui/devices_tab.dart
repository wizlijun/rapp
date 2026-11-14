// Devices tab of the side panel: 本机, each remote device's apps, add device.
import 'dart:io';

import 'package:flutter/material.dart';

import '../hub_client.dart';
import '../pages/app_profile_page.dart';
import '../permissions.dart';
import 'add_device_form.dart';
import 'controls.dart';
import 'lamp.dart';
import 'lifecycle.dart';
import 'main_state.dart';
import 'session_model.dart';
import 'tab_chip.dart';
import 'tokens.dart';

TextStyle _mono(RappTokens t, {double size = 12, Color? color}) => TextStyle(
      fontFamily: t.mono,
      fontFamilyFallback: t.monoFallback,
      fontSize: size,
      color: color ?? t.muted,
    );

/// The host part of A's first LAN address that another machine can reach ("ip:port" or
/// "[v6]:port"); null when there is none (loopback only, or unknown).
String? screenShareHost(List<String> lan) {
  for (final a in lan) {
    final v6 = a.startsWith('[');
    final end = v6 ? a.indexOf(']') : a.lastIndexOf(':');
    final host = v6 ? (end > 0 ? a.substring(1, end) : '') : (end > 0 ? a.substring(0, end) : a);
    final ip = InternetAddress.tryParse(host);
    if (ip != null && !ip.isLoopback) return host;
  }
  return null;
}

class DevicesTab extends StatefulWidget {
  const DevicesTab(
      {super.key,
      required this.state,
      required this.local,
      this.localBadge = false,
      this.screenShare,
      this.relaySet = false});
  final MainState state;

  /// The 本机 content, assembled by the caller.
  final Widget local;

  /// A new version is on its way in: a still, muted dot on 本机 (K27).
  final bool localBadge;

  /// Opens Apple's 屏幕共享 to A at this host (B types A's login password there itself;
  /// rapp never holds it). Null where there is no such app: no button.
  final Future<void> Function(String host)? screenShare;

  /// This machine has a relay set: hosts are added by bare ID.
  final bool relaySet;

  @override
  State<DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends State<DevicesTab> {
  final _bundle = TextEditingController();
  final _requested = <String>{};

  MainState get state => widget.state;

  @override
  void initState() {
    super.initState();
    // After the first frame: probing notifies listeners, which must not
    // happen while the tree is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) => state.refreshDevices());
  }

  @override
  void dispose() {
    _bundle.dispose();
    super.dispose();
  }

  void _select(String? id) {
    state.selectDevice(id);
    if (id == null) return;
    final p = state.probes[id];
    if (p == null || p.lamp != Lamp.connecting) state.probe(id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final hosts = state.hub?.hosts ?? const [];
        final sel = state.deviceTab;
        final known = sel != null && hosts.any((h) => h.id == sel);
        // Hosts that arrived after the first probe pass get probed once.
        final fresh = [
          for (final h in hosts)
            if (!state.probes.containsKey(h.id) && _requested.add(h.id)) h.id,
        ];
        if (fresh.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            for (final id in fresh) {
              if (!state.probes.containsKey(id)) state.probe(id);
            }
          });
        }
        // Three fixed slots: the form's State must survive tab switches.
        return ListView(
          padding: const EdgeInsets.all(10),
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  // The dot is hidden from screen readers; the name says it instead.
                  Semantics(
                    container: true,
                    button: true,
                    selected: !known,
                    label: widget.localBadge ? '本机，有新版本' : '本机',
                    excludeSemantics: true,
                    onTap: () => _select(null),
                    child: TabChip(
                      key: const Key('device-local'),
                      label: '本机',
                      selected: !known,
                      leading: widget.localBadge ? const _UpdateDot() : null,
                      onTap: () => _select(null),
                    ),
                  ),
                  for (final h in hosts) ...[
                    const SizedBox(width: 6),
                    _deviceChip(h.id, h.id == sel),
                  ],
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 10),
                if (!known) widget.local else ..._remote(context, sel),
                const SizedBox(height: 16),
              ],
            ),
            if (state.hub != null)
              AddDeviceForm(
                hub: state.hub!,
                enabled: state.hubUsable,
                relaySet: widget.relaySet,
                onAdded: (id) {
                  state.selectDevice(id);
                  state.probe(id);
                },
              ),
          ],
        );
      },
    );
  }

  Widget _deviceChip(String id, bool selected) {
    final p = state.probes[id];
    final lamp = p?.lamp ?? Lamp.connecting;
    final name = state.deviceName(id);
    return TabChip(
      key: Key('device-$id'),
      label: p == null ? name : '$name，${p.word}',
      selected: selected,
      leading: StatusLamp(lamp),
      onTap: () => _select(id),
    );
  }

  SessionEntry? _session(String id, String app) {
    for (final g in state.groups) {
      for (final e in g.entries) {
        if (e.key == '$id/$app') return e;
      }
    }
    return null;
  }

  List<Widget> _remote(BuildContext context, String id) {
    final t = RappTokens.of(context);
    final p = state.probes[id];
    final apps = p?.apps;
    final name = state.deviceName(id);
    final missing = missingPermissions(apps?.permissions);
    final pathWord = apps == null ? '' : (pathLabels[apps.path] ?? '');
    final share = widget.screenShare;
    final shareHost = share == null
        ? null
        : screenShareHost([
            for (final h in state.hub?.hosts ?? const <HubHost>[])
              if (h.id == id) ...h.lan
          ]);
    return [
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 4,
        children: [
          Text(name, style: TextStyle(color: t.text, fontWeight: FontWeight.w600)),
          Text(id, style: _mono(t)),
          if (p != null)
            Row(mainAxisSize: MainAxisSize.min, children: [
              StatusLamp(p.lamp),
              const SizedBox(width: 6),
              Text(p.word, style: TextStyle(color: t.muted)),
            ]),
          if (pathWord.isNotEmpty) Text(pathWord, style: TextStyle(color: t.muted)),
          if (share != null && shareHost != null)
            RappButton.secondary(
              key: const Key('screen-share'),
              label: '用屏幕共享打开',
              semanticLabel: '用屏幕共享打开 $name（可在那里解锁）',
              onPressed: () => share(shareHost),
            ),
          // Keyed per device: an armed confirm never carries over to another device.
          KeyedSubtree(
            key: ValueKey('remove:$id'),
            child: ConfirmButton(
              key: const Key('remove-device'),
              label: '删除设备',
              onConfirmed: state.hubUsable ? () => state.removeDevice(id) : null,
            ),
          ),
        ],
      ),
      if (p?.error != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(disconnectWord(p!.error), style: TextStyle(color: t.accent)),
        ),
      if (missing.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(remoteHint(name, missing), style: TextStyle(color: t.accent)),
        ),
      const SizedBox(height: 8),
      if (apps != null && apps.apps.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('对方没有可共享的窗口', style: TextStyle(color: t.muted)),
        ),
      if (apps != null)
        for (final a in apps.apps)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _AppRow(
              id: id,
              app: a.app,
              name: a.name,
              session: _session(id, a.app),
              enabled: state.hubUsable,
              favorite: state.isFavorite(id, a.app),
              onFavorite: () => state.toggleFavorite(id, a.app, a.name),
              onProfile: () => openAppProfilePage(context, state.profiles, appId: a.app, appName: a.name),
              onOpen: () => state.openOrSwitch(id, a.app, a.name),
            ),
          ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('bundle-id'),
              controller: _bundle,
              decoration: const InputDecoration(
                labelText: '其他 app 的包名（例：com.apple.TextEdit）',
                isDense: true,
              ),
              onSubmitted: (_) => _openBundle(id),
            ),
          ),
          const SizedBox(width: 8),
          RappButton.secondary(
            key: const Key('open-bundle'),
            label: '打开',
            onPressed: state.hubUsable ? () => _openBundle(id) : null,
          ),
        ],
      ),
    ];
  }

  void _openBundle(String id) {
    final b = _bundle.text.trim();
    if (b.isEmpty) return;
    state.openOrSwitch(id, b, b);
  }
}

/// 8 px, `--muted`, never moves: an update waits at the edge (design language §0 check 2).
class _UpdateDot extends StatelessWidget {
  const _UpdateDot();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Container(
          key: const Key('update-dot'),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: RappTokens.of(context).muted, shape: BoxShape.circle),
        ),
      );
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.id,
    required this.app,
    required this.name,
    required this.session,
    required this.enabled,
    required this.favorite,
    required this.onFavorite,
    required this.onProfile,
    required this.onOpen,
  });
  final String id, app, name;
  final SessionEntry? session;
  final bool enabled;
  final bool favorite;
  final VoidCallback onFavorite;
  final VoidCallback onProfile;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final lamp = session?.lamp ?? Lamp.notOpened;
    final word = lampWord(lamp);
    final connecting = lamp == Lamp.connecting;
    final verb = openVerb(session?.lamp, takenOver: session?.takenOver ?? false);
    final favLabel = favorite ? '取消常用' : '设为常用';
    final backdrop = rowBackdrop(lamp, t);
    final dashed = lamp == Lamp.notOpened;
    final border = rowBorder(lamp, t);
    final radius = BorderRadius.circular(t.r);
    return SizedBox(
      key: Key('app-$app'),
      height: 68,
      child: CustomPaint(
        foregroundPainter: dashed ? DashedOutline(t.line, t.r) : null,
        child: Container(
          decoration: dashed
              ? t.panelBox(border: Colors.transparent)
              : t.panelBox(border: border),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              children: [
                if (backdrop != null) Positioned.fill(child: DecoratedBox(decoration: backdrop)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      StatusLamp(lamp),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: t.text, fontWeight: FontWeight.w600),
                            ),
                            Text(app, maxLines: 1, overflow: TextOverflow.ellipsis, style: _mono(t)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        key: Key('profile-$app'),
                        icon: const Icon(Icons.more_horiz),
                        tooltip: 'app 配置',
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        onPressed: onProfile,
                      ),
                      const SizedBox(width: 6),
                      RappButton.secondary(
                        key: Key('fav-$app'),
                        label: favLabel,
                        semanticLabel: '$favLabel $name',
                        onPressed: onFavorite,
                      ),
                      const SizedBox(width: 6),
                      RappButton.secondary(
                        key: Key('open-$app'),
                        label: verb,
                        semanticLabel: '$verb $name，$word',
                        onPressed: (enabled && !connecting) ? onOpen : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
