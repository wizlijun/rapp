// The top bar's traffic label: five bars and the rate (design language: bars lit = --on, dark = --line).
import 'package:flutter/material.dart';

import '../ui/tokens.dart';

/// How many of the five bars are lit for [bytesPerSecond] (KB = 1000 B).
int levelBars(int bytesPerSecond) {
  if (bytesPerSecond <= 0) return 0;
  if (bytesPerSecond < 5000) return 1;
  if (bytesPerSecond < 15000) return 2;
  if (bytesPerSecond < 40000) return 3;
  if (bytesPerSecond < 100000) return 4;
  return 5;
}

/// "0 KB/s", "12.3 KB/s", "1.5 MB/s" (same as RappCore's `formatRate`).
String formatRate(int bytes) {
  if (bytes <= 0) return '0 KB/s';
  final kb = bytes / 1000;
  if (kb < 1000) return '${kb.toStringAsFixed(1)} KB/s';
  return '${(kb / 1000).toStringAsFixed(1)} MB/s';
}

/// The five bars alone: lit = `--on`, dark = `--line`.
class LevelBars extends StatelessWidget {
  const LevelBars(this.bytesPerSecond, {super.key});

  final int bytesPerSecond;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final lit = levelBars(bytesPerSecond);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 5; i++)
          Padding(
            padding: EdgeInsets.only(right: i < 4 ? 2 : 0),
            child: Container(
              key: Key('bar$i'),
              width: 3,
              height: 4.0 + 2 * i,
              color: i < lit ? t.on : t.line,
            ),
          ),
      ],
    );
  }
}

class TrafficLabel extends StatelessWidget {
  const TrafficLabel({
    super.key,
    required this.bytesPerSecond,
    required this.open,
    required this.onTap,
    this.onSecondaryTap,
  });

  final int bytesPerSecond;

  /// The stream menu is open: the selected style.
  final bool open;
  final VoidCallback onTap;
  final VoidCallback? onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final rate = formatRate(bytesPerSecond);
    final radius = BorderRadius.circular(t.r);
    return Semantics(
      button: true,
      selected: open,
      label: '流量 $rate，打开串流菜单',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onSecondaryTap: onSecondaryTap,
          borderRadius: radius,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: open
                ? t.raiseBox(border: t.text)
                : BoxDecoration(borderRadius: radius, border: Border.all(color: Colors.transparent)),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                LevelBars(bytesPerSecond),
                const SizedBox(width: 8),
                Text(
                  rate,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: t.mono,
                    fontFamilyFallback: t.monoFallback,
                    fontSize: 12,
                    color: t.text,
                    fontWeight: open ? FontWeight.w600 : FontWeight.w400,
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
