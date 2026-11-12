// 资源 tab of the side panel (S6 K13): every session's clipboard entries on top, this launch's
// file transfers below (running, then ended). Global lists live here and in the stream menu's
// corner, never on the stage.
import 'package:flutter/material.dart';

import '../embed/session_port.dart';
import 'controls.dart';
import 'lamp.dart';
import 'main_state.dart';
import 'resources_state.dart';
import 'tokens.dart';

class ResourcesTab extends StatelessWidget {
  const ResourcesTab({super.key, required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final r = state.resources;
        final clips = r.clips;
        final running = r.running;
        final ended = r.ended;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _Half(
                title: '剪贴板',
                children: [
                  if (clips.isEmpty) const _Empty('还没有剪贴板条目'),
                  for (final e in clips) _ClipRow(key: Key('clip-${e.seq}'), state: state, entry: e),
                ],
              ),
            ),
            Divider(height: 1, color: RappTokens.of(context).line),
            Expanded(
              child: _Half(
                title: '文件',
                children: [
                  const _Sub('进行中'),
                  if (running.isEmpty) const _Empty('没有进行中的传输'),
                  for (final x in running) _RunningRow(key: Key('run-${x.sid}-${x.id}'), state: state, row: x),
                  const _Sub('传过的'),
                  if (ended.isEmpty) const _Empty('这次启动还没有传过文件'),
                  for (final x in ended) _EndedRow(key: Key('ended-${x.sid}-${x.id}'), state: state, row: x),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Half extends StatelessWidget {
  const _Half({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(title, style: TextStyle(color: t.muted, fontSize: 12, letterSpacing: t.labelSpacing * 12)),
        ),
        ...children,
      ],
    );
  }
}

class _Sub extends StatelessWidget {
  const _Sub(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Text(text, style: TextStyle(color: t.text, fontWeight: FontWeight.w600)),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text, style: TextStyle(color: RappTokens.of(context).muted)),
      );
}

/// The small tag of a clipboard entry; its border style says the kind (design language §3, K14):
/// text single solid, image dashed, files double, data dashed, other double and grey.
class KindTag extends StatelessWidget {
  const KindTag(this.kind, {super.key});
  final ClipKind kind;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final grey = kind == ClipKind.unsupported;
    final color = grey ? t.muted : t.text;
    final line = grey ? t.muted : t.line;
    final label = Text(kindWord(kind), style: TextStyle(color: color, fontSize: 12));
    const pad = EdgeInsets.symmetric(horizontal: 6, vertical: 2);
    final radius = BorderRadius.circular(t.r);
    final Widget tag = switch (kind) {
      ClipKind.text => DecoratedBox(
          decoration: BoxDecoration(border: Border.all(color: line), borderRadius: radius),
          child: Padding(padding: pad, child: label),
        ),
      ClipKind.image || ClipKind.data => CustomPaint(
          painter: DashedOutline(line, t.r),
          child: Padding(padding: pad, child: label),
        ),
      ClipKind.files || ClipKind.unsupported => DecoratedBox(
          decoration: BoxDecoration(border: Border.all(color: line), borderRadius: radius),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: DecoratedBox(
              decoration: BoxDecoration(border: Border.all(color: line), borderRadius: radius),
              child: Padding(padding: pad, child: label),
            ),
          ),
        ),
    };
    return Semantics(label: kindWord(kind), excludeSemantics: true, child: tag);
  }
}

TextStyle _mono(RappTokens t) =>
    TextStyle(fontFamily: t.mono, fontFamilyFallback: t.monoFallback, color: t.text);

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: t.line), borderRadius: BorderRadius.circular(t.r)),
      child: child,
    );
  }
}

class _ClipRow extends StatelessWidget {
  const _ClipRow({super.key, required this.state, required this.entry});
  final MainState state;
  final ClipEntry entry;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final e = entry;
    final blocked = state.copyBlockedWord(e);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              KindTag(e.kind),
              const SizedBox(width: 8),
              Expanded(
                child: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: _mono(t)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text('${e.source} · ${hhmm(e.at)}', style: TextStyle(color: t.muted, fontSize: 12)),
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 6,
            children: [
              RappButton.secondary(
                key: Key('pin-${e.seq}'),
                label: e.pinned ? '取消固定' : '固定',
                onPressed: e.pinned || state.canPin(e) ? () => state.togglePin(e) : null,
              ),
              RappButton.secondary(
                key: Key('copy-${e.seq}'),
                label: blocked ?? '复制到本机',
                onPressed: blocked == null ? () => state.copyLocal(e) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RunningRow extends StatelessWidget {
  const _RunningRow({super.key, required this.state, required this.row});
  final MainState state;
  final TransferRow row;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final x = row;
    final frac = x.total > 0 ? (x.done / x.total).clamp(0.0, 1.0) : 0.0;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const StatusLamp(Lamp.connecting),
              const SizedBox(width: 8),
              Text(x.down ? '↓ 从 A' : '↑ 到 A', style: TextStyle(color: t.muted)),
              const SizedBox(width: 8),
              Expanded(child: Text(x.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: _mono(t))),
              const SizedBox(width: 8),
              Text('${(frac * 100).floor()}%', style: _mono(t)),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: frac, color: t.on, backgroundColor: t.line, minHeight: 4),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: Text(x.source, style: TextStyle(color: t.muted, fontSize: 12))),
              RappButton.secondary(
                key: Key('cancel-${x.sid}-${x.id}'),
                label: '取消',
                onPressed: () => state.cancelTransfer(x),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EndedRow extends StatelessWidget {
  const _EndedRow({super.key, required this.state, required this.row});
  final MainState state;
  final TransferRow row;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final x = row;
    final done = x.state == TransferState.done;
    final size = done
        ? sizeText(x.total)
        : x.state == TransferState.cancelled
            ? '已取消'
            : '没传完';
    final at = x.endedAt;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(x.down ? '↓' : '↑', style: TextStyle(color: t.muted)),
              const SizedBox(width: 8),
              Expanded(child: Text(x.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: _mono(t))),
              const SizedBox(width: 8),
              Text(size, style: TextStyle(color: done ? t.text : t.muted)),
            ],
          ),
          const SizedBox(height: 2),
          Text('${x.source}${at == null ? '' : ' · ${hhmm(at)}'}', style: TextStyle(color: t.muted, fontSize: 12)),
          if (done && !x.down && x.kind == ClipKind.files) // K10: only a file lands in a folder on A
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('A：~/Downloads/rapp/${x.name}', style: TextStyle(color: t.muted, fontSize: 12)),
            ),
          if (done && x.down && x.path != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerRight,
                child: RappButton.secondary(
                  key: Key('reveal-${x.sid}-${x.id}'),
                  label: '显示位置',
                  onPressed: () => state.reveal(x),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
