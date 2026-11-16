// Grayscale over everything outside the focus panes (智能 preset): A's focus rects stay colour.
import 'package:flutter/material.dart';

/// Luma (77/150/29 of 256) into all three channels.
const lumaFilter = ColorFilter.matrix(<double>[
  77 / 256, 150 / 256, 29 / 256, 0, 0, //
  77 / 256, 150 / 256, 29 / 256, 0, 0,
  77 / 256, 150 / 256, 29 / 256, 0, 0,
  0, 0, 0, 1, 0,
]);

/// Everything in [size] except [rects] (picture-local).
class OutsideClipper extends CustomClipper<Path> {
  OutsideClipper(this.rects);
  final List<Rect> rects;

  @override
  Path getClip(Size size) {
    // The union of the rects is cut out, so overlapping rects never turn back to gray (even-odd would).
    var hole = Path();
    for (final r in rects) {
      hole = Path.combine(PathOperation.union, hole, Path()..addRect(r));
    }
    return Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), hole);
  }

  @override
  bool shouldReclip(OutsideClipper old) => !_same(old.rects, rects);

  static bool _same(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Debug: a frame around each focus rect, to see what A picked. Hidden by default;
/// on for now while the rules are being tuned on real apps. Set to false to hide it.
const showFocusFrames = true;

/// The gray layer over a picture of [size]: what is behind it, outside [rects], turns gray.
/// With [frames], each rect also gets a debug frame in [frameColor] drawn just inside it
/// (the theme's `on` colour at the call site, so it follows the theme).
Widget focusGray(Size size, List<Rect> rects, {required Color frameColor, bool frames = showFocusFrames}) =>
    IgnorePointer(
      key: const Key('focus-gray'),
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipPath(
              clipper: OutsideClipper(rects),
              child: const BackdropFilter(filter: lumaFilter, child: SizedBox.expand()),
            ),
          ),
          if (frames)
            for (final r in rects)
              Positioned.fromRect(
                rect: r,
                child: DecoratedBox(
                  key: const Key('focus-debug-frame'),
                  decoration: BoxDecoration(border: Border.fromBorderSide(BorderSide(color: frameColor, width: 2))),
                ),
              ),
        ],
      ),
    );
