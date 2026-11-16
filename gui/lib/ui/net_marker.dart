// The top bar's network marker (spec 2026-11-14-rapp-network-status §4.1): the level's mark, left
// of the traffic label. The four marks are four animals of their own speed — cheetah, rabbit,
// tortoise, and a cracked egg for a link that never hatched — so the shape alone tells the levels
// apart without colour, and nothing about it looks like a wifi fan.
import 'package:flutter/material.dart';

import '../hub_client.dart';
import 'session_model.dart';

/// A round trip at or above this is weak (§3.4); a segment of the path is judged by it too.
const weakRttMs = 300;

String netWord(NetLevel l) => switch (l) {
      NetLevel.strong => '强',
      NetLevel.ok => '一般',
      NetLevel.weak => '弱',
      NetLevel.down => '断开',
    };

/// The level's mark: a 14×14 pt pixel sprite in black, white and gray on transparent, in
/// `assets/net/`, with exact 2.0x and 3.0x variants beside it. Drawn in its own colours, never
/// tinted as a template (that would flatten the white and gray detail); the white fill keeps it
/// readable on a dark bar, the black outline on a light one. The shape alone tells the levels apart.
String netAsset(NetLevel l) => 'assets/net/${l.name}.png';

/// `本机网络 · 一般 · 中继 160ms · 丢包 3%`, and a second line when the current session's [path]
/// is `lan` or `direct` (it does not go through the relay).
String netTooltip(NetStatus n, {String? path}) {
  final parts = ['本机网络', netWord(n.level)];
  if (n.level != NetLevel.down) {
    if (n.rttMs != null) parts.add('中继 ${n.rttMs}ms');
    parts.add('丢包 ${(n.loss * 100).round()}%');
  }
  final off = path == 'lan' || path == 'direct';
  return parts.join(' · ') + (off ? '\n当前会话走${routeWord(path)}，不经过中继' : '');
}

/// The mark alone; the words (the tooltip's) are in its hover and atop the traffic menu.
class NetMarker extends StatelessWidget {
  const NetMarker({super.key, required this.net, this.path});

  final NetStatus net;

  /// The current session's path, for the tooltip.
  final String? path;

  /// The mark's canvas, the same for all four levels.
  static const markSize = Size(14, 14);

  /// Width the marker takes in the top bar: the mark and 6 either side.
  static const width = 26.0;

  @override
  Widget build(BuildContext context) {
    final tip = netTooltip(net, path: path);
    return Tooltip(
      message: tip,
      child: Semantics(
        key: const Key('net-marker'),
        label: tip,
        excludeSemantics: true,
        child: Container(
          width: width,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.centerLeft,
          child: Image.asset(
            netAsset(net.level),
            key: const Key('net-mark'),
            width: markSize.width,
            height: markSize.height,
            // Pixel art: the 2.0x/3.0x variants are exact multiples, so never smooth it.
            filterQuality: FilterQuality.none,
            excludeFromSemantics: true,
          ),
        ),
      ),
    );
  }
}
