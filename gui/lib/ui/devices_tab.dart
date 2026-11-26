// Devices tab of the side panel: 本机, each remote device's apps, add device.
import 'package:flutter/material.dart';

import '../hub_client.dart';
import '../pages/app_profile_page.dart';
import '../permissions.dart';
import '../shares.dart';
import '../term/term_id.dart';
import 'add_device_form.dart';
import 'controls.dart';
import 'inline_edit.dart';
import 'lamp.dart';
import 'lifecycle.dart';
import 'main_state.dart';
import 'session_model.dart';
import 'tab_chip.dart';
import 'term_restore_dialog.dart';
import 'term_status.dart';
import 'shares_section.dart';
import 'terms_entry.dart';
import 'tokens.dart';

TextStyle _mono(RappTokens t, {Color? color}) => TextStyle(
      fontFamily: t.mono,
      fontFamilyFallback: t.monoFallback,
      color: color ?? t.muted,
    );

class DevicesTab extends StatefulWidget {
  const DevicesTab(
      {super.key,
      required this.state,
      required this.local,
      this.localBadge = false,
      this.shares});
  final MainState state;

  /// The 本机 content, assembled by the caller.
  final Widget local;

  /// A new version is on its way in: a still, muted dot on 本机 (K27).
  final bool localBadge;

  /// Asked for each device's shared ports; null leaves the 端口 section out.
  final SharesApi? shares;

  @override
  State<DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends State<DevicesTab> {
  final _bundle = TextEditingController();
  final _requested = <String>{};

  /// The ＋ is open: the add form shows right under the top row.
  bool _adding = false;

  /// Per device: the shell button being opened, and the words of the last refused open.
  final _shellBusy = <String, String>{};
  final _shellErrors = <String, String>{};

  /// Per device: the words of the last refused rename.
  final _renameErrors = <String, String>{};

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
        // Fixed, keyed slots: the add form's State (typed text, its error) must survive device switches.
        return ListView(
          padding: const EdgeInsets.all(10),
          children: [
            _topRow(context, hosts, known ? sel : null),
            if (_adding && state.hub != null)
              Padding(
                key: const ValueKey('add-slot'),
                padding: const EdgeInsets.only(top: 10),
                child: Container(
                  key: const Key('add-device-box'),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(RappTokens.of(context).r),
                    border: Border.all(color: RappTokens.of(context).line),
                  ),
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
              ),
            Column(
              key: const ValueKey('device-body'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 10),
                if (!known) widget.local else ..._remote(context, sel),
                const SizedBox(height: 16),
              ],
            ),
          ],
        );
      },
    );
  }

  /// The device's name and its probe word, as the picker and its menu show it.
  String _label(String id) {
    final p = state.probes[id];
    final name = state.deviceName(id);
    return p == null ? name : '$name，${p.word}';
  }

  /// 本机 first and on its own, then one picker for every other device (any number of them stays reachable, where
  /// a row of chips ran off the panel's side), then the ＋ that opens the add form right under this row.
  Widget _topRow(BuildContext context, List<HubHost> hosts, String? sel) {
    final t = RappTokens.of(context);
    final label = sel == null ? (hosts.isEmpty ? '还没有其他设备' : '其他设备') : _label(sel);
    final picker = RappDropdown<String>(
        key: const Key('device-picker'),
        expand: true,
        menuConstraints: (w) => BoxConstraints(minWidth: w, maxWidth: w),
        enabled: hosts.isNotEmpty,
        arrow: hosts.isNotEmpty,
        semanticLabel: '其他设备：$label',
        selected: sel != null,
        dim: sel == null,
        current: sel,
        label: Row(children: [
          if (sel != null) ...[StatusLamp(_lamp(sel)), const SizedBox(width: 8)],
          Expanded(child: Text(label, key: const Key('device-picker-label'))),
          if (hosts.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text('${hosts.length} 台', style: TextStyle(color: t.muted, fontWeight: FontWeight.normal)),
          ],
        ]),
        items: [
          for (final h in hosts)
            RappMenuItem<String>(
              key: Key('device-${h.id}'),
              value: h.id,
              label: _label(h.id),
              lead: StatusLamp(_lamp(h.id)),
            ),
        ],
        onSelected: _select,
      );
    return Row(children: [
      // The dot is hidden from screen readers; the name says it instead.
      Semantics(
        container: true,
        button: true,
        selected: sel == null,
        label: widget.localBadge ? '本机，有新版本' : '本机',
        excludeSemantics: true,
        onTap: () => _select(null),
        child: TabChip(
          key: const Key('device-local'),
          label: '本机',
          selected: sel == null,
          leading: widget.localBadge ? const _UpdateDot() : null,
          onTap: () => _select(null),
        ),
      ),
      const SizedBox(width: 6),
      Expanded(child: picker),
      if (state.hub != null) ...[
        const SizedBox(width: 6),
        _adding
            ? RappButton.secondary(
                key: const Key('add-device-toggle'),
                label: '收起添加设备',
                semanticLabel: '收起添加设备',
                icon: Icons.close,
                onPressed: () => setState(() => _adding = false),
              )
            : RappButton.primary(
                key: const Key('add-device-toggle'),
                label: '添加设备',
                semanticLabel: '添加设备',
                icon: Icons.add,
                onPressed: () => setState(() => _adding = true),
              ),
      ],
    ]);
  }

  Lamp _lamp(String id) => state.probes[id]?.lamp ?? Lamp.connecting;

  SessionEntry? _session(String id, String app) {
    for (final g in state.groups) {
      for (final e in g.entries) {
        if (e.key == '$id/$app' && e.standby == null) return e;
      }
    }
    return null;
  }

  List<Widget> _remote(BuildContext context, String id) {
    final t = RappTokens.of(context);
    final p = state.probes[id];
    final apps = p?.apps;
    final name = state.deviceName(id);
    final graphical = apps?.capabilities?['graphical'] != false;
    final applications = graphical && apps?.capabilities?['applications'] != false;
    final missing = graphical ? missingPermissions(apps?.permissions) : <Permission>[];
    final forced = state.forcedRelay(id);
    final pathWord = routeWord(state.pathOf(id), forced: forced);
    final terms = state.hub?.termLists[id];
    final ordered = apps == null ? const <HubApp>[] : orderApps(apps.apps, entry: showsTermsEntry(terms));
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
          // 网络弱: a session of it through the relay is slow on the relay-to-host part.
          if (pathWord.isNotEmpty)
            Text(state.peerWeak(id) ? '$pathWord · 网络弱' : pathWord, style: TextStyle(color: t.muted)),
          // Only with a relay set: without one there is nothing to force onto.
          if (state.relaySet)
            RappButton.secondary(
              key: const Key('route-toggle'),
              label: forced ? '恢复自动' : '强制走中继',
              onPressed: state.hubUsable ? () => state.setRoute(id, !forced) : null,
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
      if (apps?.permissions?['platform'] == 'linux' && apps?.permissions?['error'] is String)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(apps!.permissions!['error'] as String, style: TextStyle(color: t.accent)),
        ),
      const SizedBox(height: 8),
      if (apps != null && apps.apps.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(apps.capabilities?['graphical'] == false ? '这台设备支持文本终端和端口分享，暂不提供应用画面' : '对方没有可共享的窗口', style: TextStyle(color: t.muted)),
        ),
      // 桌面 first, 终端 second (spec §2.1), the rest in their order.
      if (ordered.firstOrNull?.app == 'desktop:') _appRow(context, id, ordered.first),
      ..._termsEntry(context, id, terms, apps?.apps ?? const [], graphical: applications),
      for (final a in ordered)
        if (a.app != 'desktop:') _appRow(context, id, a),
      if (widget.shares != null) SharesSection(key: ValueKey('shares-$id'), api: widget.shares!, to: id),
      const SizedBox(height: 8),
      if (applications) Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('bundle-id'),
              controller: _bundle,
              decoration: const InputDecoration(
                labelText: '其他 app 的包名（例：com.apple.TextEdit）',
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

  Widget _appRow(BuildContext context, String id, HubApp a) => Padding(
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
      );

  /// The 终端 row and, below it and always expanded, its sessions, terminal apps and 打开方式.
  List<Widget> _termsEntry(BuildContext context, String id, TermList? list, List<HubApp> apps, {required bool graphical}) {
    final t = RappTokens.of(context);
    if (list != null && !list.off && list.error != null) {
      return [Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('终端：${list.error}', style: TextStyle(color: t.accent)))];
    }
    if (!showsTermsEntry(list)) return const [];
    final launchers = list!.hosts.where((h) => h.host == null).firstOrNull?.launchers ?? const <String>[];
    final mode = graphical ? state.prefs.termOpenFor(id) : 'text';
    final termApp = launchers.isEmpty ? null : state.prefs.termAppFor(id, launchers);
    final shells = list.hosts.where((h) => h.host == null).firstOrNull?.shells;
    // (key, label, path); an old device lists none and gets one 默认 shell that sends no shell.
    final shellButtons = shells == null
        ? const [('default', '默认 shell', null as String?)]
        : [
            for (final x in [...shells.where((x) => x.isDefault), ...shells.where((x) => !x.isDefault)])
              (x.name, x.name, x.path as String?),
          ];
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: _AppRow(
          id: id,
          app: termsEntry,
          name: termsEntryName,
          session: null,
          enabled: state.hubUsable,
          favorite: state.isFavorite(id, termsEntry),
          onFavorite: () => state.toggleFavorite(id, termsEntry, termsEntryName),
          onOpen: () => state.openOrSwitch(id, termsEntry, termsEntryName),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 16, bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (list.terms.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('这台设备上现在没有终端会话。', style: TextStyle(color: t.muted)),
              ),
            for (final r in list.terms)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _TermRow(
                  row: r,
                  session: _session(id, r.id),
                  enabled: state.hubUsable && state.embeds,
                  onOpen: () => state.openOrSwitch(id, r.id, termDisplayName(r.shown, r.host)),
                  onRename: shells == null ? null : (v) => _rename(id, r, v),
                ),
              ),
            if (state.savedTerms(id).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('上次没关的 ${state.savedTerms(id).length} 个终端', key: const Key('saved-terms-label'), style: TextStyle(color: t.text)),
                    RappButton.secondary(
                      key: const Key('saved-terms-restore'),
                      label: '恢复…',
                      onPressed: state.hubUsable ? () => showTermRestore(context, state, id) : null,
                    ),
                  ],
                ),
              ),
            if (_renameErrors[id] != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(_renameErrors[id]!, key: const Key('rename-error'), style: TextStyle(color: t.accent)),
              ),
            for (final a in graphical ? terminalAppsOf(apps) : const <HubApp>[])
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _PixelsRow(
                  app: a,
                  session: _session(id, a.app),
                  enabled: state.hubUsable,
                  onOpen: () => state.openOrSwitch(id, a.app, a.name),
                ),
              ),
            if (launchers.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('新开', style: TextStyle(color: t.text)),
                    for (final (key, label, path) in shellButtons)
                      RappButton.secondary(
                        key: Key('new-shell-$key'),
                        label: label,
                        onPressed: state.hubUsable && !_shellBusy.containsKey(id) ? () => _openShell(id, key, path) : null,
                      ),
                  ],
                ),
              ),
              if (_shellErrors[id] != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(_shellErrors[id]!, key: const Key('new-shell-error'), style: TextStyle(color: t.accent)),
                ),
              if (launchers.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('终端 app', style: TextStyle(color: t.text)),
                      for (final l in launchers)
                        RappChoice(
                            key: Key('term-app-$l'),
                            label: l,
                            selected: termApp == l,
                            onTap: () => state.setTermApp(id, l)),
                    ],
                  ),
                ),
            ],
            Row(
              children: [
                Text('打开方式', style: TextStyle(color: t.text)),
                const SizedBox(width: 12),
                RappChoice(
                    key: const Key('term-open-text'),
                    label: '文本',
                    selected: mode == 'text',
                    onTap: () => state.setTermOpen(id, 'text')),
                if (graphical) ...[
                  const SizedBox(width: 12),
                  RappChoice(
                      key: const Key('term-open-pixels'),
                      label: '画面',
                      selected: mode == 'pixels',
                      onTap: () => state.setTermOpen(id, 'pixels')),
                ],
              ],
            ),
          ],
        ),
      ),
    ];
  }

  /// Renames [r] on [id]; an unchanged name sends nothing, a refusal shows under the list.
  Future<void> _rename(String id, TermRow r, String name) async {
    if (name.trim() == r.shown) {
      if (_renameErrors.containsKey(id)) setState(() => _renameErrors.remove(id));
      return;
    }
    setState(() => _renameErrors.remove(id));
    try {
      await state.renameTerm(id, r.id, name);
    } catch (e) {
      final words = e is HubException ? e.message : e is FormatException ? e.message : '$e';
      if (mounted) setState(() => _renameErrors[id] = words);
    }
  }

  /// Opens [path] (null: the device's default) on [id]; the button stays busy until the answer.
  Future<void> _openShell(String id, String key, String? path) async {
    setState(() {
      _shellBusy[id] = key;
      _shellErrors.remove(id);
    });
    try {
      await state.waits.run('正在打开终端…', () => state.openText(id, shell: path, from: state.newTermSource(id)),
          detail: state.deviceName(id), words: MainState.newTermWords, asks: MainState.consentError);
    } catch (e) {
      if (mounted) setState(() => _shellErrors[id] = e is HubException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _shellBusy.remove(id));
    }
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
    this.onProfile,
    required this.onOpen,
  });
  final String id, app, name;
  final SessionEntry? session;
  final bool enabled;
  final bool favorite;
  final VoidCallback onFavorite;

  /// Null leaves the ⋯ out (the 终端 entry has no app 配置).
  final VoidCallback? onProfile;
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
                      if (onProfile != null) ...[
                        IconButton(
                          key: Key('profile-$app'),
                          icon: Icon(Icons.more_horiz, size: 20, color: t.text),
                          tooltip: 'app 配置',
                          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                          onPressed: onProfile,
                        ),
                        const SizedBox(width: 6),
                      ],
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

class _TermRow extends StatelessWidget {
  const _TermRow({required this.row, required this.session, required this.enabled, required this.onOpen, this.onRename});
  final TermRow row;
  final SessionEntry? session;
  final bool enabled;
  final VoidCallback onOpen;

  /// Null on a device too old to rename: the name is then plain text.
  final ValueChanged<String>? onRename;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final name = termDisplayName(row.shown, row.host);
    final status = termStatus(row, now);
    final verb = openVerb(session?.lamp, takenOver: session?.takenOver ?? false);
    return Container(
      key: Key('term-${row.id}'),
      constraints: const BoxConstraints(minHeight: 68),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: t.panelBox(border: t.line),
      child: Row(
        children: [
          StatusLamp(termLamp(row, now)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: onRename == null
                        ? Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.text, fontWeight: FontWeight.w600))
                        : InlineEdit(
                            key: Key('term-name-${row.id}'),
                            text: row.shown,
                            semanticLabel: '改名 $name',
                            style: TextStyle(color: t.text, fontWeight: FontWeight.w600),
                            onCommit: onRename!,
                          ),
                  ),
                ]),
                Text(row.command, maxLines: 1, overflow: TextOverflow.ellipsis, style: _mono(t)),
                Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.muted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          RappButton.secondary(
            key: Key('open-${row.id}'),
            label: verb,
            semanticLabel: '$verb $name，$status',
            onPressed: enabled ? onOpen : null,
          ),
        ],
      ),
    );
  }
}

/// A terminal app inside 终端: its windows are seen as pictures only.
class _PixelsRow extends StatelessWidget {
  const _PixelsRow({required this.app, required this.session, required this.enabled, required this.onOpen});
  final HubApp app;
  final SessionEntry? session;
  final bool enabled;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final lamp = session?.lamp ?? Lamp.notOpened;
    return Container(
      key: Key('term-app-${app.app}'),
      constraints: const BoxConstraints(minHeight: 68),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: t.panelBox(border: t.line),
      child: Row(
        children: [
          StatusLamp(lamp),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(app.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text, fontWeight: FontWeight.w600)),
                Text('只能用画面看', style: TextStyle(color: t.muted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          RappButton.secondary(
            key: Key('pixels-${app.app}'),
            label: '画面',
            semanticLabel: '画面 ${app.name}，${lampWord(lamp)}',
            onPressed: enabled && lamp != Lamp.connecting ? onOpen : null,
          ),
        ],
      ),
    );
  }
}
