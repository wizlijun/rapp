import 'package:flutter/material.dart';

/// Where a menu opened at global point [p] goes, inside [context]'s overlay.
RelativeRect menuAt(BuildContext context, Offset p) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  return RelativeRect.fromLTRB(p.dx, p.dy, overlay.size.width - p.dx, overlay.size.height - p.dy);
}

/// A window rule was just added: say so, with 撤销 running [undo].
void ruleSnack(ScaffoldMessengerState messenger, String text, VoidCallback undo) {
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Text(text),
    action: SnackBarAction(label: '撤销', onPressed: undo),
    // With an action, Flutter keeps the snackbar up until it is tapped;
    // this one is a heads-up, so let it go on its own.
    persist: false,
  ));
}
