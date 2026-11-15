// A session row (60px: lamp, name, route or reason, status) and a group title, shared by the side
// panel's 会话 tab and the top bar's session list.
import 'package:flutter/material.dart';

import '../embed/traffic_label.dart' show formatRate;
import 'lamp.dart';
import 'session_model.dart';
import 'tokens.dart';

class SessionGroupTitle extends StatelessWidget {
  const SessionGroupTitle(this.title, {super.key, this.onTap});
  final String title;

  /// A project's name is a button (切到); the other titles are plain text.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final text = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, color: t.muted, letterSpacing: 11 * t.labelSpacing),
    );
    if (onTap == null) {
      return Padding(padding: const EdgeInsets.fromLTRB(2, 10, 2, 6), child: text);
    }
    return Semantics(
      button: true,
      label: title,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          alignment: Alignment.centerLeft,
          child: text,
        ),
      ),
    );
  }
}

class SessionRow extends StatelessWidget {
  const SessionRow({
    super.key,
    required this.entry,
    this.forced = false,
    required this.selected,
    required this.byDevice,
    required this.embedded,
    required this.onTap,
  });
  final SessionEntry entry;

  /// The host is forced onto the relay: its relay path reads 「中继（强制）」.
  final bool forced;
  final bool selected;
  final bool byDevice;

  /// Only embedded sessions have traffic data; other rows are unchanged (R22).
  final bool embedded;
  final VoidCallback onTap;

  String get _second {
    final path = routeWord(entry.path, forced: forced);
    if (byDevice) return path;
    return path.isEmpty ? entry.device : '${entry.device} · $path';
  }

  /// The status text at the row's right (R22): the rate when active, 「空闲」, 「连接中」; empty
  /// when disconnected (its reason takes the second line) or when there is no data.
  String get _status {
    if (!embedded || entry.reason != null) return '';
    return switch (entry.lamp) {
      Lamp.active => entry.bytesPerSecond == null ? '' : formatRate(entry.bytesPerSecond!),
      Lamp.idle => '空闲',
      Lamp.connecting => '连接中',
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final backdrop = rowBackdrop(entry.lamp, t);
    final border = rowBorder(entry.lamp, t, selected: selected);
    final reason = entry.reason == null ? null : '已断开：${entry.reason}';
    final pane = entry.paneTitle ?? '';
    final second = [reason ?? _second, pane].where((s) => s.isNotEmpty).join(' · ');
    final status = _status;
    final label = [
      entry.appName,
      // The state word is said once: 「空闲」 and 「连接中」 are both lamp and status.
      if (status != lampWord(entry.lamp)) lampWord(entry.lamp),
      if (status.isNotEmpty) status,
      if (second.isNotEmpty) second,
    ].join('，');
    final small = Theme.of(context).textTheme.bodySmall;
    return SizedBox(
      key: Key('session-${entry.key}'),
      height: 60,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(t.r),
            child: Container(
              decoration: t.panelBox(border: border),
              child: Stack(
                children: [
                  if (backdrop != null)
                    Positioned.fill(child: DecoratedBox(decoration: backdrop)),
                  if (selected)
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: DecoratedBox(
                          key: Key('inner-stroke-${entry.key}'),
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular((t.r - 2).clamp(0, t.r)),
                            border: Border.all(color: t.text),
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        StatusLamp(entry.lamp),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.appName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: t.text,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (second.isNotEmpty)
                                Text(
                                  second,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: small?.copyWith(color: t.muted),
                                ),
                            ],
                          ),
                        ),
                        if (embedded && (entry.reason != null || status.isNotEmpty))
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              status,
                              key: Key('session-status-${entry.key}'),
                              maxLines: 1,
                              style: TextStyle(
                                fontFamily: t.mono,
                                fontFamilyFallback: t.monoFallback,
                                fontSize: 12,
                                color: t.muted,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
