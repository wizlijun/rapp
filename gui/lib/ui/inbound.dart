// 正在被接入: the sessions other devices hold on this machine, as the overview's 本机 column lists them.
// They are not tasks: nothing opens on a tap; each one can only be cut off (断开).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../hub_client.dart';
import '../service_client.dart';
import '../term/term_id.dart';
import 'controls.dart';
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

const _cardHeight = 56.0;

/// 正在被接入 · N and one card per session; nothing at all when [sessions] is empty. The ages tick once a second
/// while there is something to show.
class InboundGroup extends StatefulWidget {
  const InboundGroup({super.key, required this.sessions, required this.hosts, required this.now, required this.onKick});
  final List<ServiceSession> sessions;
  final List<HubHost> hosts;
  final DateTime Function() now;
  final Future<void> Function(Object sid) onKick;

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

  @override
  Widget build(BuildContext context) {
    final sessions = widget.sessions;
    if (sessions.isEmpty) return const SizedBox.shrink();
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    final now = widget.now();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text('正在被接入 · ${sessions.length}',
            key: const Key('inbound-title'), style: small?.copyWith(letterSpacing: t.labelSpacing * t.textSize)),
      ),
      for (final (i, s) in sessions.indexed) ...[
        if (i > 0) const SizedBox(height: 8),
        _InboundCard(
          session: s,
          title: inboundTitle(s.app),
          subtitle: inboundSubtitle(s, widget.hosts, now),
          spoken: '${inboundWho(s, widget.hosts)}${s.side ? '，传文件' : ''}',
          onKick: () => _kick(s.sid),
        ),
      ],
    ]);
  }
}

/// A dashed, inert card: it reads 正在被接入 to a screen reader and only its 断开 does anything.
class _InboundCard extends StatelessWidget {
  const _InboundCard(
      {required this.session, required this.title, required this.subtitle, required this.spoken, required this.onKick});
  final ServiceSession session;
  final String title;
  final String subtitle;

  /// Who is in, for a screen reader: without the age, so the label does not change every second.
  final String spoken;
  final VoidCallback onKick;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    return SizedBox(
      key: Key('inbound-${session.sid}'),
      height: _cardHeight,
      child: Semantics(
        container: true,
        label: '正在被接入，$title，$spoken',
        child: CustomPaint(
          painter: _DashedFrame(color: t.muted, radius: t.r),
          child: Padding(
            padding: const EdgeInsets.only(left: 10, right: 2),
            child: Row(children: [
              ExcludeSemantics(child: Icon(Icons.login, size: 16, color: t.muted)),
              const SizedBox(width: 10),
              Expanded(
                child: ExcludeSemantics(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text)),
                      Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                    ],
                  ),
                ),
              ),
              RappButton.quiet(key: Key('inbound-kick-${session.sid}'), label: '断开', onPressed: onKick),
            ]),
          ),
        ),
      ),
    );
  }
}

class _DashedFrame extends CustomPainter {
  const _DashedFrame({required this.color, required this.radius});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)).deflate(.5);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const dash = 4.0, gap = 3.0;
    for (final metric in (Path()..addRRect(rect)).computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        canvas.drawPath(metric.extractPath(d, math.min(d + dash, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedFrame old) => old.color != color || old.radius != radius;
}
