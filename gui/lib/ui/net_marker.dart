// The top bar's network marker (spec 2026-11-14-rapp-network-status §4.1): the level's mark, left
// of the traffic label. The four marks are four animals of their own speed — cheetah, rabbit,
// tortoise, and a cracked egg for a link that never hatched — so the shape alone tells the levels
// apart without colour, and nothing about it looks like a wifi fan.
import 'package:flutter/material.dart';

import '../hub_client.dart';
import 'session_model.dart';
import 'tokens.dart';

/// A round trip at or above this is weak (§3.4); a segment of the path is judged by it too.
const weakRttMs = 300;

String netWord(NetLevel l) => switch (l) {
      NetLevel.strong => '强',
      NetLevel.ok => '一般',
      NetLevel.weak => '弱',
      NetLevel.down => '断开',
    };

/// The level's mark: a 28×14 pt black-on-transparent PNG in `assets/net/`, with 2.0x and 3.0x
/// variants beside it, drawn as a template image (tinted by [netColor], alpha kept). The art is
/// optically sized inside the one canvas, so it is never cropped, stretched or scaled on its own.
String netAsset(NetLevel l) => 'assets/net/${l.name}.png';

/// Strong in the lamps' on colour, ok in the text colour, weak in the warning colour (the accent, as the
/// lamps use it), down in the theme's error colour.
Color netColor(NetLevel l, RappTokens t, ColorScheme cs) => switch (l) {
      NetLevel.strong => t.on,
      NetLevel.ok => t.text,
      NetLevel.weak => t.accent,
      NetLevel.down => cs.error,
    };

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
  static const markSize = Size(28, 14);

  /// Width the marker takes in the top bar.
  static const width = 40.0;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final color = netColor(net.level, t, Theme.of(context).colorScheme);
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
            // Template rendering: the black art takes the level's colour, the transparent ground
            // stays clear, so it sits right on a light or a dark bar.
            color: color,
            filterQuality: FilterQuality.medium,
            excludeFromSemantics: true,
          ),
        ),
      ),
    );
  }
}
