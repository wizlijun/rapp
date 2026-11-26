// A session as the overview shows it (lamp, title, windows, what it is doing), shared by the overview's
// columns and the top bar's session list so the two say the same.
import 'package:flutter/material.dart';

import '../embed/traffic_label.dart' show LevelBars, formatRate;
import 'lamp.dart';
import 'main_state.dart';
import 'overview_model.dart' show windowsWord;
import 'session_model.dart';
import 'term_status.dart' show programWord;
import 'tokens.dart';

const sessionBlockHeight = 56.0;

class SessionBlock extends StatelessWidget {
  const SessionBlock({super.key, required this.state, required this.entry, this.onTap, this.keyPrefix = 'block'});
  final MainState state;
  final SessionEntry entry;

  /// What a tap does besides switching to [entry] (the top bar's list closes itself).
  final VoidCallback? onTap;

  /// Its keys: `<keyPrefix>-<key>` and `frame-<keyPrefix>-<key>`, so the overview's and the list's differ.
  final String keyPrefix;

  /// What a terminal's program says it is doing, while the session itself is up; it takes the traffic's place.
  String? get _program {
    final ps = entry.ps;
    if (ps == null) return null;
    return switch (entry.lamp) {
      Lamp.disconnected || Lamp.connecting || Lamp.offline => null,
      _ => programWord(ps),
    };
  }

  String get _status => _program ?? switch (entry.lamp) {
        Lamp.active => '活动',
        Lamp.disconnected => entry.reason == null ? '已断开' : '已断开：${entry.reason}',
        final l => lampWord(l),
      };

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final selected = entry.key == state.currentKey;
    final backdrop = rowBackdrop(entry.lamp, t);
    final border = rowBorder(entry.lamp, t, selected: selected);
    final windows = windowsWord(state.windowsOf(entry.key));
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: t.muted);
    final rate = state.embeds && entry.lamp == Lamp.active && _program == null;
    void onTap() {
      state.select(entry.key);
      this.onTap?.call();
    }
    final radius = BorderRadius.circular(t.r);
    return SizedBox(
      key: Key('$keyPrefix-${entry.key}'),
      height: sessionBlockHeight,
      child: Semantics(
        button: true,
        selected: selected,
        label: [entry.title, _status, if (_program != null && entry.inferred) '推断', ?windows].join('，'),
        excludeSemantics: true,
        onTap: onTap,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: Container(
              key: Key('frame-$keyPrefix-${entry.key}'),
              decoration: t.panelBox().copyWith(border: Border.all(color: border, width: selected ? 2 : 1)),
              child: Stack(children: [
                if (backdrop != null) Positioned.fill(child: DecoratedBox(decoration: backdrop)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(children: [
                    StatusLamp(entry.lamp),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(
                              child: Text(
                                entry.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: t.text, fontWeight: FontWeight.w600),
                              ),
                            ),
                            if (windows != null) Text(windows, maxLines: 1, style: small),
                          ]),
                          if (rate)
                            Row(children: [
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
                            ])
                          else if (_program != null && entry.inferred)
                            Row(children: [
                              Flexible(child: Text(_status, maxLines: 1, overflow: TextOverflow.ellipsis, style: small)),
                              const SizedBox(width: 6),
                              Text('推断', maxLines: 1, style: small),
                            ])
                          else
                            Text(entry.noted(_status), maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                        ],
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
