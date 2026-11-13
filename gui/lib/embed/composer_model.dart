// The composer's draft for one session (R18): the text, the block chips, open or not, and the
// status line. The runner holds what the blocks stand for and does the sending.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'session_port.dart';

enum SendOutcome {
  /// Nothing to send: keys go to A directly (the status says so).
  empty,

  /// A snapshot was taken; the caller sends `pieces()` to the runner.
  sent,

  /// A send is still running.
  ignored,
}

/// macOS virtual key code of Return, what the after-send step presses.
const returnKeyCode = 36;

class ComposerModel extends ChangeNotifier {
  /// [onDrop]: a block left the editor (removed, or sent); the runner forgets what it held.
  /// [onAllSent]: a send round put every piece into A (not partial, failed or cancelled).
  ComposerModel({this.onDrop, this.onAllSent});

  final void Function(int n)? onDrop;
  final VoidCallback? onAllSent;

  /// The editor's text and cursor.
  final TextEditingController controller = TextEditingController();

  String get text => controller.text;
  set text(String v) => controller.value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));

  /// The chips, in the order they were added.
  final List<BlockChip> blocks = [];

  bool _open = false;
  bool get open => _open;
  set open(bool v) {
    if (_open == v) return;
    _open = v;
    notifyListeners();
  }

  /// A send round is running (from `send()` until `done`).
  bool sending = false;

  /// A short line under the editor; clears by itself.
  String? status;

  ({List<int> blocks, String text})? _snapshot;
  Timer? _statusTimer;
  bool _copyPending = false;
  bool _disposed = false;

  /// What goes to A, in order: the blocks as added, then the text if any (R3).
  List<Map<String, Object>> pieces() => [
        for (final b in blocks) {'block': b.n},
        if (text.isNotEmpty) {'text': text},
      ];

  /// The user pressed send (or Enter).
  SendOutcome send() {
    if (sending) return SendOutcome.ignored;
    if (blocks.isEmpty && text.isEmpty) {
      _show('按键直接发给 A', const Duration(seconds: 5));
      notifyListeners();
      return SendOutcome.empty;
    }
    _snapshot = (blocks: [for (final b in blocks) b.n], text: text);
    sending = true;
    notifyListeners();
    return SendOutcome.sent;
  }

  /// The runner's `sending`; a stop before `done` is held until `done` comes.
  void setSending(bool on) {
    if (!on && _snapshot != null) return;
    if (sending == on) return;
    sending = on;
    notifyListeners();
  }

  /// A send round ended: the first [sent] pieces went. They leave the editor unless the user
  /// changed that part meanwhile; [failure] (empty: cancelled, the strip said why) is shown.
  void done(int sent, String? failure) {
    final snap = _snapshot;
    _snapshot = null;
    sending = false;
    String? note;
    final allSent = snap != null &&
        failure == null &&
        sent > 0 &&
        sent == snap.blocks.length + (snap.text.isNotEmpty ? 1 : 0);
    if (snap != null && sent > 0) {
      final sentBlocks = snap.blocks.take(sent).toList();
      final textSent = sent > snap.blocks.length && snap.text.isNotEmpty;
      final current = [for (final b in blocks) b.n];
      final blocksSame =
          current.length >= sentBlocks.length && listEquals(current.sublist(0, sentBlocks.length), sentBlocks);
      final textSame = !textSent || text.startsWith(snap.text);
      if (blocksSame && textSame) {
        final gone = blocks.sublist(0, sentBlocks.length);
        blocks.removeRange(0, sentBlocks.length);
        for (final b in gone) {
          onDrop?.call(b.n);
        }
        if (textSent) _dropTextPrefix(snap.text.length);
      } else {
        note = '（发送中改过内容，未清除）';
      }
    }
    final shown = [if (failure != null && failure.isNotEmpty) failure, ?note];
    if (shown.isNotEmpty) _show(shown.join(' '), const Duration(seconds: 5));
    notifyListeners();
    if (allSent) onAllSent?.call();
  }

  /// The first [n] characters went: the rest stays, its cursor and composing range shifted.
  void _dropTextPrefix(int n) {
    final v = controller.value;
    final rest = v.text.substring(n);
    int shift(int i) => i < 0 ? i : (i - n).clamp(0, rest.length);
    final sel = v.selection;
    final c = v.composing;
    final composing = c.isValid && c.end > n ? TextRange(start: shift(c.start), end: shift(c.end)) : TextRange.empty;
    controller.value = TextEditingValue(
      text: rest,
      selection: sel.isValid
          ? sel.copyWith(baseOffset: shift(sel.baseOffset), extentOffset: shift(sel.extentOffset))
          : TextSelection.collapsed(offset: rest.length),
      composing: composing,
    );
  }

  /// Bumped when the field should take the caret (a clip's 「插入」); the bar follows it.
  int focusTick = 0;

  /// The field should take the caret, even from a focused picture.
  void wantFocus() {
    focusTick++;
    notifyListeners();
  }

  /// Esc in the editor: clears the text; with none, the composer closes (R16).
  void esc() {
    if (text.isNotEmpty) {
      text = '';
    } else {
      _open = false;
    }
    notifyListeners();
  }

  /// 「复制」 was pressed (the caller sent ⌘C to A): A's clipboard should change within 2 s.
  void copyPressed() {
    _copyPending = true;
    status = '已复制';
    _statusTimer?.cancel();
    _statusTimer = Timer(const Duration(seconds: 2), () {
      if (!_copyPending) return;
      _copyPending = false;
      _show('A 上没有复制到东西', const Duration(seconds: 2));
      notifyListeners();
    });
    notifyListeners();
  }

  /// A's clipboard changed.
  void clipArrived() {
    if (!_copyPending) return;
    _copyPending = false;
    _show('已复制', const Duration(seconds: 2));
    notifyListeners();
  }

  /// A paste, attach or insert result: text at the cursor, blocks as chips, a status shown.
  /// Ignored once the session is gone (a runner answer can come after).
  void apply(PasteResult r) {
    if (_disposed) return;
    final t = r.text;
    if (t != null && t.isNotEmpty) insertText(t);
    blocks.addAll(r.blocks);
    final s = r.status;
    if (s != null) _show(s, const Duration(seconds: 5));
    notifyListeners();
  }

  /// [s] replaces the selection (or goes at the end without one); the cursor lands after it.
  void insertText(String s) {
    final v = controller.value;
    final sel = v.selection;
    final start = sel.isValid ? sel.start : v.text.length;
    final end = sel.isValid ? sel.end : v.text.length;
    controller.value = TextEditingValue(
      text: v.text.replaceRange(start, end, s),
      selection: TextSelection.collapsed(offset: start + s.length),
    );
  }

  /// The user tapped chip [n] away.
  void removeBlock(int n) {
    final i = blocks.indexWhere((b) => b.n == n);
    if (i < 0) return;
    blocks.removeAt(i);
    onDrop?.call(n);
    notifyListeners();
  }

  void _show(String s, Duration d) {
    _copyPending = false;
    status = s;
    _statusTimer?.cancel();
    _statusTimer = Timer(d, () {
      status = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _statusTimer?.cancel();
    controller.dispose();
    super.dispose();
  }
}
