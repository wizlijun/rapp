// A session as the overview shows it (lamp, title, windows, what it is doing), and a 常用 app that is not
// open: the one card every list of sessions uses (overview columns, the top bar's list, the side panel's
// 会话 tab), so they all say the same. Places differ only in the parameters.
import 'package:flutter/material.dart';

import '../embed/traffic_label.dart' show LevelBars, formatRate;
import '../labels.dart';
import 'controls.dart' show DashedOutline, RappButton, RappMenuItem, menuAt, showRappMenu;
import 'lamp.dart';
import 'main_state.dart';
import 'overview_model.dart' show windowsWord;
import 'session_model.dart';
import '../term/term_id.dart' show isTermApp, termKindWord;
import 'term_status.dart' show programWord;
import 'tokens.dart';
import 'workspace_store.dart' show AppRef;

const sessionBlockHeight = 56.0;

/// A card with a note line (spec §4.6): each card in a list takes the height its content needs.
const sessionBlockNoteHeight = 72.0;

/// What a card's label menu (right-click, long-press) changes, and how. One menu for every card that lists a session.
class LabelEdit {
  const LabelEdit({
    required this.label,
    required this.defaultTitle,
    required this.save,
    required this.reset,
    required this.say,
    this.offline = false,
  });

  /// The label now; null for none (还原 is not offered).
  final SessionLabel? label;

  /// What the title is with no label: 「留空用默认：…」.
  final String defaultTitle;
  final Future<void> Function(String title, String note) save;
  final Future<void> Function() reset;

  /// Where a word about what happened goes (the top bar's hint, or a snack).
  final void Function(String words) say;

  /// The device is off line: the items are grey, with 「设备离线，连上后再改」.
  final bool offline;
}

/// Opens the label menu at [at] (global): 改标题和备注… (a dialog), and 还原 when there is a label (at once, no
/// confirming: one tap).
Future<void> showLabelMenu(BuildContext context, Offset at, LabelEdit edit) async {
  final pick = await showRappMenu<String>(
    context,
    position: menuAt(context, at),
    items: [
      RappMenuItem(key: const Key('label-edit'), value: 'edit', label: '改标题和备注…', enabled: !edit.offline),
      if (edit.label != null)
        RappMenuItem(key: const Key('label-reset'), value: 'reset', label: '还原', enabled: !edit.offline),
      if (edit.offline) const RappMenuItem.caption(label: '设备离线，连上后再改'),
    ],
  );
  if (pick == null || !context.mounted) return;
  if (pick == 'edit') {
    await showDialog<void>(
      context: context,
      builder: (_) => LabelDialog(edit: edit),
    );
    return;
  }
  try {
    await edit.reset();
    edit.say('已还原，标题回到 ${edit.defaultTitle}');
  } catch (e) {
    edit.say('还原失败：$e');
  }
}

/// 改标题和备注: a title line and a note line, the default title in grey under them; a refusal stays in red under
/// them and the dialog stays open.
class LabelDialog extends StatefulWidget {
  const LabelDialog({super.key, required this.edit});
  final LabelEdit edit;

  @override
  State<LabelDialog> createState() => _LabelDialogState();
}

class _LabelDialogState extends State<LabelDialog> {
  late final _title = TextEditingController(text: widget.edit.label?.title ?? '');
  late final _note = TextEditingController(text: widget.edit.label?.note ?? '');
  String? _error;
  var _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = cleanLabelTitle(_title.text), note = cleanLabelNote(_note.text);
    final why = title.error ?? note.error;
    if (why != null) return setState(() => _error = why);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.edit.save(title.value!, note.value!);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return AlertDialog(
      title: const Text('改标题和备注'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('label-title'),
              controller: _title,
              autofocus: true,
              maxLines: 1,
              decoration: const InputDecoration(labelText: '标题'),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('label-note'),
              controller: _note,
              maxLines: 1,
              decoration: const InputDecoration(labelText: '备注'),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 8),
            Text('留空用默认：${widget.edit.defaultTitle}', style: TextStyle(color: t.muted)),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _error!,
                  key: const Key('label-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        RappButton.secondary(key: const Key('label-cancel'), label: '取消', onPressed: () => Navigator.pop(context)),
        RappButton.secondary(key: const Key('label-save'), label: '保存', onPressed: _saving ? null : _save),
      ],
    );
  }
}

/// The one card frame every session card is (spec §7.8): the lamp (or [leading]), the title with [windows] at its
/// right, [second] under it, the note line when there is a [note], and [trailing] at the right. Dashed for a session
/// that is not open here. With [labels] a right-click or a long-press opens the label menu.
class SessionCard extends StatelessWidget {
  const SessionCard({
    super.key,
    required this.frameKey,
    required this.lamp,
    required this.title,
    required this.second,
    required this.spoken,
    this.note = '',
    this.windows,
    this.selected = false,
    this.dashed = false,
    this.leading,
    this.trailing,
    this.onTap,
    this.labels,
    this.backdrop,
    this.border,
    this.titleColor,
  });
  final Key frameKey;
  final Lamp lamp;
  final String title, note;
  final Widget second;

  /// What a screen reader says for the card.
  final String spoken;
  final String? windows;
  final bool selected, dashed;

  /// In place of the lamp (the 正在被接入 card's sign).
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final LabelEdit? labels;
  final Decoration? backdrop;
  final Color? border;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    final radius = BorderRadius.circular(t.r);
    final body = Stack(
      children: [
        if (backdrop != null) Positioned.fill(child: DecoratedBox(decoration: backdrop!)),
        Padding(
          padding: EdgeInsets.only(left: 10, right: trailing == null ? 10 : 2),
          child: Row(
            children: [
              ExcludeSemantics(child: leading ?? StatusLamp(lamp)),
              const SizedBox(width: 10),
              Expanded(
                child: ExcludeSemantics(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: titleColor ?? t.text,
                                fontWeight: dashed ? null : FontWeight.w600,
                              ),
                            ),
                          ),
                          if (windows != null) Text(windows!, maxLines: 1, style: small),
                        ],
                      ),
                      second,
                      if (note.isNotEmpty)
                        Tooltip(
                          message: note,
                          child: Text(note, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                        ),
                    ],
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ],
    );
    final framed = dashed
        ? CustomPaint(key: frameKey, foregroundPainter: DashedOutline(border ?? t.line, t.r), child: body)
        : Container(
            key: frameKey,
            decoration: t.panelBox().copyWith(
              border: Border.all(color: border ?? t.line, width: selected ? 2 : 1),
            ),
            child: body,
          );
    Widget card = Semantics(
      button: onTap != null,
      selected: selected,
      label: [spoken, if (note.isNotEmpty) note].join('，'),
      container: true,
      onTap: onTap,
      child: Material(
        type: MaterialType.transparency,
        child: onTap == null ? framed : InkWell(onTap: onTap, borderRadius: radius, child: framed),
      ),
    );
    final l = labels;
    if (l != null) {
      card = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (d) => showLabelMenu(context, d.globalPosition, l),
        onLongPressStart: (d) => showLabelMenu(context, d.globalPosition, l),
        child: card,
      );
    }
    return SizedBox(height: note.isEmpty ? sessionBlockHeight : sessionBlockNoteHeight, child: card);
  }
}

class SessionBlock extends StatelessWidget {
  const SessionBlock({
    super.key,
    required this.state,
    required this.entry,
    this.onTap,
    this.keyPrefix = 'block',
    this.showDevice = false,
  });
  final MainState state;
  final SessionEntry entry;

  /// What a tap does besides switching to [entry] (the top bar's list closes itself).
  final VoidCallback? onTap;

  /// Its keys: `<keyPrefix>-<key>` and `frame-<keyPrefix>-<key>`, so the overview's and the list's differ.
  final String keyPrefix;

  /// The second line starts with the device's name: where the group title does not say it (by app, by project).
  final bool showDevice;

  /// A terminal's program, when the title no longer names it: a label's title stands in its place.
  String? get _kind {
    if (!isTermApp(entry.app)) return null;
    final named = entry.label?.title.isNotEmpty == true;
    if (named) return entry.fg == null || entry.fg!.isEmpty ? termKindWord : entry.fg;
    return entry.kindNoted ? termKindWord : null;
  }

  /// What the second line starts with, whichever way it goes on: the terminal's kind ([_kind]), then the device when
  /// [showDevice]; null for neither.
  String? get _lead {
    final parts = [?_kind, if (showDevice) entry.device];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  String _led(String line) => _lead == null ? line : '$_lead · $line';

  /// The second line of a 别处开着 card: the terminal's kind, the device it runs on, then [SessionEntry.openOn] where
  /// the status goes, with what its program says it is doing.
  String get _openOnLine => [?_kind, entry.device, entry.openOn!, ?_program].join(' · ');

  /// What a terminal's program says it is doing, while the session itself is up; it takes the traffic's place.
  String? get _program {
    final ps = entry.ps;
    if (ps == null) return null;
    return switch (entry.lamp) {
      Lamp.disconnected || Lamp.connecting || Lamp.offline => null,
      Lamp.notOpened when entry.standby != Standby.open => null,
      _ => programWord(ps),
    };
  }

  String get _status =>
      _program ??
      switch (entry.standby) {
        Standby.stopped => '已停止',
        Standby.open => '没有打开',
        null => switch (entry.lamp) {
          Lamp.active => '活动',
          Lamp.disconnected => entry.reason == null ? '已断开' : '已断开：${entry.reason}',
          final l => lampWord(l),
        },
      };

  /// The label menu, where the device's table has come (an older device: none).
  LabelEdit? _labels() {
    if (!state.labelsReady(entry.id)) return null;
    return LabelEdit(
      label: entry.label,
      defaultTitle: entry.defaultTitle,
      offline: state.deviceOffline(entry.id),
      save: (title, note) => state.setLabel(entry.id, entry.app, title: title, note: note),
      reset: () => state.resetLabel(entry.id, entry.app),
      say: state.say,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final standby = entry.standby;
    final selected = standby == null && entry.key == state.currentKey;
    final windows = standby == null ? windowsWord(state.windowsOf(entry.key)) : null;
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    final rate = standby == null && state.embeds && entry.lamp == Lamp.active && _program == null;
    final canAct = standby == null || (state.hubUsable && !state.deviceOffline(entry.id));
    void onTap() {
      if (standby != null) {
        state.openStandby(entry);
      } else {
        state.select(entry.key);
      }
      this.onTap?.call();
    }

    final verb = switch (standby) {
      Standby.stopped => '启动',
      Standby.open => '打开',
      null => null,
    };
    final Widget second;
    if (rate) {
      second = Row(
        children: [
          if (_lead != null) Text('$_lead · ', maxLines: 1, style: small),
          LevelBars(entry.bytesPerSecond ?? 0),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              formatRate(entry.bytesPerSecond ?? 0),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: small?.copyWith(fontFamily: t.mono, fontFamilyFallback: t.monoFallback),
            ),
          ),
        ],
      );
    } else if (_program != null && entry.inferred) {
      second = Row(
        children: [
          Flexible(
            child: Text(_led(_status), maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
          ),
          const SizedBox(width: 6),
          Text('推断', maxLines: 1, style: small),
        ],
      );
    } else {
      final line = entry.openOn == null ? _led(_status) : _openOnLine;
      second = Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: small);
    }
    return KeyedSubtree(
      key: Key('$keyPrefix-${entry.key}'),
      child: SessionCard(
        frameKey: Key('frame-$keyPrefix-${entry.key}'),
        lamp: entry.lamp,
        title: entry.title,
        note: entry.note,
        second: second,
        windows: windows,
        selected: selected,
        dashed: standby != null,
        backdrop: standby == null ? rowBackdrop(entry.lamp, t) : null,
        border: standby == null ? rowBorder(entry.lamp, t, selected: selected) : null,
        titleColor: canAct ? null : t.muted,
        trailing: verb == null || !canAct
            ? null
            : Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ExcludeSemantics(child: Text(verb, style: small)),
              ),
        spoken: [
          entry.title,
          if (entry.openOn != null) _openOnLine else ...[?_lead, _status],
          if (_program != null && entry.inferred) '推断',
          ?windows,
          if (verb != null && canAct) '点按$verb',
        ].join('，'),
        onTap: canAct ? onTap : null,
        labels: _labels(),
      ),
    );
  }
}

/// A favourite that is not open: dashed, 「点按打开」; greyed while it cannot open. With [device] (a list whose
/// group title does not name it) the device's name goes on a second line and the card is a session card's height.
class FavoriteBlock extends StatelessWidget {
  const FavoriteBlock({
    super.key,
    required this.favorite,
    required this.label,
    required this.verb,
    required this.onTap,
    this.keyPrefix = 'ov-favorite',
    this.device,
  });
  final AppRef favorite;
  final String label, verb;
  final VoidCallback? onTap;

  /// Its key: `<keyPrefix>-<key>`.
  final String keyPrefix;
  final String? device;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    final radius = BorderRadius.circular(t.r);
    return SizedBox(
      key: Key('$keyPrefix-${favorite.key}'),
      height: device == null ? 48 : sessionBlockHeight,
      child: Semantics(
        button: true,
        enabled: onTap != null,
        label: '常用 $label，${device == null ? '' : '$device，'}${onTap != null ? '点按$verb' : '现在打不开'}',
        excludeSemantics: true,
        onTap: onTap,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: CustomPaint(
              foregroundPainter: DashedOutline(t.line, t.r),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    const StatusLamp(Lamp.notOpened),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: onTap != null ? t.text : t.muted),
                          ),
                          if (device != null) Text(device!, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                        ],
                      ),
                    ),
                    if (onTap != null) Text(verb, style: small),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
