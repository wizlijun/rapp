// The remote window's picture on the stage: the runner's texture, letterboxed.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../ui/tokens.dart';
import 'geometry.dart';
import 'remote_session.dart';
import 'session_port.dart';

class Picture extends StatefulWidget {
  const Picture({super.key, required this.session, required this.window, this.hole});
  final RemoteSession session;
  final RemoteWindow window;

  /// Receives the texture's global rect (R25), so the IRON MAN grid can leave it alone.
  final ValueNotifier<Rect?>? hole;

  @override
  State<Picture> createState() => _PictureState();
}

class _PictureState extends State<Picture> {
  final _tex = GlobalKey();
  Rect? _mine;

  void _report() {
    final h = widget.hole;
    if (h == null || !mounted) return;
    final box = _tex.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final r = box.localToGlobal(Offset.zero) & box.size;
    if (r == _mine && h.value == r) return;
    _mine = r;
    h.value = r;
  }

  @override
  void dispose() {
    final h = widget.hole, mine = _mine;
    if (h != null && mine != null) {
      // Not while the tree is being torn down; and not over a newer picture's rect.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (h.value == mine) h.value = null;
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final win = widget.window;
    SchedulerBinding.instance.addPostFrameCallback((_) => _report());
    return LayoutBuilder(builder: (context, c) {
      final fit = fitRect(contentSize(win), c.biggest);
      final pic = pictureRect(fit, win.visible);
      return ColoredBox(
        color: t.bg,
        child: Stack(children: [
          Positioned.fromRect(rect: pic, child: Texture(key: _tex, textureId: win.texture!)),
        ]),
      );
    });
  }
}
