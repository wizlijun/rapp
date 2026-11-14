// The top bar's traffic label: five bars and the rate (design language: bars lit = --on, dark = --line).
import 'package:flutter/material.dart';

import 'dart:math' as math;

import '../hub_client.dart';
import '../ui/net_marker.dart' show weakRttMs;
import '../ui/tokens.dart';

/// The two segments of a relayed session's round trip (spec 2026-11-14-rapp-network-status §4.2):
/// this device to the relay ([local], the network marker's) and, worked out, the relay to the other
/// device ([peer] = whole − local). Null where a part is not known.
typedef Segments = ({int? whole, int? local, int? peer});

Segments segments({required String path, int? wholeMs, NetStatus? net}) {
  final local = path == 'relay' && net != null && net.level != NetLevel.down ? net.rttMs : null;
  final peer = wholeMs != null && local != null ? math.max(0, wholeMs - local) : null;
  return (whole: wholeMs, local: local, peer: peer);
}

/// The word after the rate: which end is weak when the path tells (relayed sessions only), else
/// the saving level A is at; null when all is well.
String? trafficWord({required int saving, bool localWeak = false, bool peerWeak = false}) {
  if (localWeak && peerWeak) return '弱网';
  if (localWeak) return '本机网络弱';
  if (peerWeak) return '对方网络弱';
  if (saving > 0) return '省流·$saving';
  return null;
}

/// [trafficWord] for a session on [path] with its round trip [wholeMs] and saving level.
String? sessionTrafficWord({required String path, required int saving, int? wholeMs, NetStatus? net}) {
  if (path != 'relay') return trafficWord(saving: saving);
  final seg = segments(path: path, wholeMs: wholeMs, net: net);
  final localWeak = net?.level == NetLevel.weak;
  final peerWeak = seg.peer != null ? seg.peer! >= weakRttMs : false;
  return trafficWord(saving: saving, localWeak: localWeak, peerWeak: peerWeak);
}

/// The 会话 group's first row after `路径 中继 · 活动`: `整条路 420ms（本机 80 · 对方约 340）` on the
/// relay (`整条路 未知` with no round trip yet, no brackets without the local part), the round trip
/// alone on a LAN or direct path, nothing when that is not known.
String? pathDetail({required String path, int? wholeMs, NetStatus? net}) {
  if (path != 'relay') return wholeMs == null ? null : '${wholeMs}ms';
  final seg = segments(path: path, wholeMs: wholeMs, net: net);
  if (seg.whole == null) return '整条路 未知';
  if (seg.local == null) return '整条路 ${seg.whole}ms';
  return '整条路 ${seg.whole}ms（本机 ${seg.local} · 对方约 ${seg.peer}）';
}

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
    this.compact = false,
    this.word,
  });

  /// Bars only, without the rate text.
  final bool compact;
  final int bytesPerSecond;

  /// What is weak, or the saving level ([trafficWord]); null shows the rate alone.
  final String? word;

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
      label: word != null ? '流量 $rate，$word，打开流量优化菜单' : '流量 $rate，打开流量优化菜单',
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
                if (!compact) const SizedBox(width: 8),
                if (!compact)
                Text(
                  word != null ? '$rate · $word' : rate,
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
