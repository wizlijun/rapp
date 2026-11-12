// Pure geometry between the stage, the picture and A's window.
import 'dart:ui';

import 'package:flutter/foundation.dart' show ValueNotifier;

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

/// Where a popup goes on the stage: attached to [parent]'s picture at its scale, with the parent's
/// content top-left as origin (the Dart `popupFrame`). [parentPicture] is the parent content's rect.
Rect popupRect(RemoteWindow popup, RemoteWindow parent, Rect parentPicture) {
  final c = contentSize(parent);
  final scale = c.width > 0 ? parentPicture.width / c.width : 1.0;
  return Rect.fromLTWH(
    parentPicture.left + scale * (popup.rect.left - parent.rect.left),
    parentPicture.top + scale * (popup.rect.top - (parent.rect.top + parent.titleBar)),
    scale * popup.rect.width,
    scale * popup.rect.height,
  );
}

/// The picture's global rect, for the IRON MAN grid to leave alone (R25). Whoever reports
/// it owns it: only the owner may clear it, so a widget handing over to its successor (a
/// reconnect swap) cannot null the rect the successor just reported, equal or not.
class PictureHole extends ValueNotifier<Rect?> {
  PictureHole() : super(null);

  Object? _owner;

  /// [owner] reports [rect], also when it equals the current one.
  void claim(Object owner, Rect rect) {
    _owner = owner;
    value = rect;
  }

  /// True if [owner] reported the current value and nobody has since.
  bool owns(Object owner, Rect rect) => identical(_owner, owner) && value == rect;

  /// Clears the rect only if [owner] still holds it.
  void release(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    value = null;
  }
}
