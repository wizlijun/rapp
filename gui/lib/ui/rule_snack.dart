import 'package:flutter/material.dart';

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
