// 正在被接入: the sessions other devices hold on this machine, as the overview's 本机 column lists them.
// They are not tasks: nothing opens on a tap; each one can only be cut off (断开).
import 'dart:async';

import 'package:flutter/material.dart';

import '../hub_client.dart';
import '../labels.dart';
import '../service_client.dart';
import '../term/term_id.dart';
import 'controls.dart';
import 'lamp.dart';
import 'session_block.dart' show LabelEdit, SessionCard;
import 'tokens.dart';

/// The card's first line: a text terminal as it is titled everywhere else, an app by its id.
String inboundTitle(String app) {
  final t = parseTermId(app);
  return t == null ? app : termTitle(termDisplayName(t.name, t.host));
}

/// Who is in: a saved device's name (matched by id, as relayed sessions carry it), then the name the peer
/// declared, then the peer as the service saw it.
String inboundWho(ServiceSession s, List<HubHost> hosts) {
  for (final h in hosts) {
    if (h.id == s.peer && h.name.isNotEmpty) return h.name;
  }
  final declared = s.name;
  return declared != null && declared.isNotEmpty ? declared : s.peer;
}

/// How long since [since] (Unix seconds), rounded down; unknown or in the future reads 0 秒.
String inboundAge(Object? since, DateTime now) {
  final secs = since is num ? now.millisecondsSinceEpoch ~/ 1000 - since.toInt() : 0;
  final d = secs < 0 ? 0 : secs;
  if (d < 60) return '$d 秒';
  if (d < 3600) return '${d ~/ 60} 分钟';
  return '${d ~/ 3600} 小时';
}

/// The card's second line.
String inboundSubtitle(ServiceSession s, List<HubHost> hosts, DateTime now) =>
    '${inboundWho(s, hosts)} · ${inboundAge(s.since, now)}${s.side ? ' · 传文件' : ''}';

/// This machine's labels, and how to change them (over the local service): the 本机 column's cards show them and
/// their menu changes them (spec §7.4).
class LocalLabels {
  const LocalLabels({required this.table, required this.set, required this.reset, required this.say});
  final LabelTable table;
  final Future<void> Function(String app, String title, String note) set;
  final Future<void> Function(String app) reset;
  final void Function(String words) say;

  LabelEdit edit(String app) => LabelEdit(
    label: table.labels[app],
    defaultTitle: inboundTitle(app),
    save: (title, note) => set(app, title, note),
    reset: () => reset(app),
    say: say,
  );
}

/// 正在被接入 · N and one card per session, then the labelled sessions nobody is in on (with [labels]); nothing at
/// all when there are neither. The ages tick once a second while someone is in.
class InboundGroup extends StatefulWidget {
  const InboundGroup({
    super.key,
    required this.sessions,
    required this.hosts,
    required this.now,
    required this.onKick,
    this.labels,
  });
  final List<ServiceSession> sessions;
  final List<HubHost> hosts;
  final DateTime Function() now;
  final Future<void> Function(Object sid) onKick;

  /// Null while the service has not said (or predates labels): no label shows and there is no menu.
  final LocalLabels? labels;

  @override
  State<InboundGroup> createState() => _InboundGroupState();
}

class _InboundGroupState extends State<InboundGroup> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(InboundGroup old) {
    super.didUpdateWidget(old);
    _follow();
  }

  void _follow() {
    if (widget.sessions.isEmpty) {
      _tick?.cancel();
      _tick = null;
    } else {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _kick(Object sid) async {
    try {
      await widget.onKick(sid);
    } catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('断开失败：$e')));
    }
  }

  Widget _heading(BuildContext context, String text, Key key) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Text(
        text,
        key: key,
        style: small?.copyWith(letterSpacing: t.labelSpacing * t.textSize),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessions = widget.sessions;
    final labels = widget.labels;
    final inApps = {for (final s in sessions) s.app};
    final idle = [
      for (final app in labels?.table.labels.keys ?? const <String>[])
        if (!inApps.contains(app)) app,
    ];
    if (sessions.isEmpty && idle.isEmpty) return const SizedBox.shrink();
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    final now = widget.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sessions.isNotEmpty) _heading(context, '正在被接入 · ${sessions.length}', const Key('inbound-title')),
        for (final (i, s) in sessions.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          _InboundCard(
            session: s,
            title: inboundTitle(s.app),
            subtitle: inboundSubtitle(s, widget.hosts, now),
            spoken: '${inboundWho(s, widget.hosts)}${s.side ? '，传文件' : ''}',
            onKick: () => _kick(s.sid),
            labels: labels,
          ),
        ],
        if (idle.isNotEmpty) _heading(context, '有标注的会话 · ${idle.length}', const Key('local-labels-title')),
        for (final (i, app) in idle.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          KeyedSubtree(
            key: Key('local-label-$app'),
            child: SessionCard(
              frameKey: Key('frame-local-label-$app'),
              lamp: Lamp.notOpened,
              title: _titled(labels!, app),
              note: labels.table.labels[app]?.note ?? '',
              second: Text(inboundTitle(app), maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
              spoken: '有标注，${_titled(labels, app)}，${inboundTitle(app)}',
              dashed: true,
              labels: labels.edit(app),
            ),
          ),
        ],
      ],
    );
  }
}

/// [app]'s label title on this machine, else what it is titled with none.
String _titled(LocalLabels? labels, String app) {
  final t = labels?.table.labels[app]?.title;
  return t == null || t.isEmpty ? inboundTitle(app) : t;
}

/// A dashed, inert card: it reads 正在被接入 to a screen reader and only its 断开 does anything (and its label menu).
class _InboundCard extends StatelessWidget {
  const _InboundCard({
    required this.session,
    required this.title,
    required this.subtitle,
    required this.spoken,
    required this.onKick,
    this.labels,
  });
  final ServiceSession session;
  final String title;
  final String subtitle;

  /// Who is in, for a screen reader: without the age, so the label does not change every second.
  final String spoken;
  final VoidCallback onKick;
  final LocalLabels? labels;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    final shown = _titled(labels, session.app);
    return KeyedSubtree(
      key: Key('inbound-${session.sid}'),
      child: SessionCard(
        frameKey: Key('frame-inbound-${session.sid}'),
        lamp: Lamp.notOpened,
        leading: Icon(Icons.login, size: 16, color: t.muted),
        title: shown,
        titleColor: t.text,
        note: labels?.table.labels[session.app]?.note ?? '',
        second: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
        spoken: '正在被接入，$shown，$spoken',
        dashed: true,
        border: t.muted,
        trailing: RappButton.quiet(key: Key('inbound-kick-${session.sid}'), label: '断开', onPressed: onKick),
        labels: labels?.edit(session.app),
      ),
    );
  }
}
