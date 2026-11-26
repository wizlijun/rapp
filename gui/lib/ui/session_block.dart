// A session as the overview shows it (lamp, title, windows, what it is doing), and a 常用 app that is not
// open: the one card every list of sessions uses (overview columns, the top bar's list, the side panel's
// 会话 tab), so they all say the same. Places differ only in the parameters.
import 'package:flutter/material.dart';

import '../embed/traffic_label.dart' show LevelBars, formatRate;
import 'controls.dart' show DashedOutline;
import 'lamp.dart';
import 'main_state.dart';
import 'overview_model.dart' show windowsWord;
import 'session_model.dart';
import '../term/term_id.dart' show termKindWord;
import 'term_status.dart' show programWord;
import 'tokens.dart';
import 'workspace_store.dart' show AppRef;

const sessionBlockHeight = 56.0;

class SessionBlock extends StatelessWidget {
  const SessionBlock({super.key, required this.state, required this.entry, this.onTap, this.keyPrefix = 'block', this.showDevice = false});
  final MainState state;
  final SessionEntry entry;

  /// What a tap does besides switching to [entry] (the top bar's list closes itself).
  final VoidCallback? onTap;

  /// Its keys: `<keyPrefix>-<key>` and `frame-<keyPrefix>-<key>`, so the overview's and the list's differ.
  final String keyPrefix;

  /// The second line starts with the device's name: where the group title does not say it (by app, by project).
  final bool showDevice;

  /// What the second line starts with, whichever way it goes on: CLI for a text terminal named after its
  /// program, then the device when [showDevice]; null for neither.
  String? get _lead {
    final parts = [if (entry.kindNoted) termKindWord, if (showDevice) entry.device];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  String _led(String line) => _lead == null ? line : '$_lead · $line';

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
        label: [entry.title, ?_lead, _status, if (_program != null && entry.inferred) '推断', ?windows].join('，'),
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
                            ])
                          else if (_program != null && entry.inferred)
                            Row(children: [
                              Flexible(child: Text(_led(_status), maxLines: 1, overflow: TextOverflow.ellipsis, style: small)),
                              const SizedBox(width: 6),
                              Text('推断', maxLines: 1, style: small),
                            ])
                          else
                            Text(_led(_status), maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
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
                child: Row(children: [
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
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
