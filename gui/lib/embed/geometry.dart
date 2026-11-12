// Pure geometry between the stage, the picture and A's window.
import 'dart:ui';

import 'session_port.dart';

/// [content] scaled to fit [box], centred; empty if either has no area.
Rect fitRect(Size content, Size box) {
  if (content.width <= 0 || content.height <= 0 || box.width <= 0 || box.height <= 0) return Rect.zero;
  final k = box.width / content.width < box.height / content.height ? box.width / content.width : box.height / content.height;
  final w = content.width * k, h = content.height * k;
  return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
}

/// Where the texture goes inside [fit]: the [visible] (0-1) part of the window content.
Rect pictureRect(Rect fit, Rect visible) => Rect.fromLTWH(
      fit.left + visible.left * fit.width,
      fit.top + visible.top * fit.height,
      visible.width * fit.width,
      visible.height * fit.height,
    );

/// A point on the picture as a point in A's window (origin top-left, title bar included).
Offset toRemote(Offset local, Rect fit, RemoteWindow w) => Offset(
      (local.dx - fit.left) / fit.width * w.rect.width,
      w.titleBar + (local.dy - fit.top) / fit.height * (w.rect.height - w.titleBar),
    );

/// The window's content size: no title bar.
Size contentSize(RemoteWindow w) => Size(w.rect.width, w.rect.height - w.titleBar);
