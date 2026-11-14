// The editing area behind the writing panel. The model never holds the text; it copies it out
// through this interface at send, session switch, 1 s idle and collapse (spec §5).
import 'package:flutter/widgets.dart';

/// What the editor reports; it never carries the text (规格 §5).
class EditorHandlers {
  const EditorHandlers({
    required this.onChanged,
    required this.onEnter,
    required this.onEscape,
    required this.onPaste,
    required this.onFocus,
  });

  /// The text changed (no text attached).
  final VoidCallback onChanged;

  /// Plain Enter, not while composing.
  final VoidCallback onEnter;

  /// Esc, not while composing.
  final VoidCallback onEscape;

  /// ⌘V (macOS) — the runner decides what it becomes.
  final VoidCallback onPaste;
  final void Function(bool on) onFocus;
}

class EditorStyle {
  const EditorStyle({required this.text, required this.color, required this.hintColor, required this.cursor});

  /// Size 15, height 22/15, theme font, shadows: [].
  final TextStyle text;
  final Color color, hintColor, cursor;
}

/// The contract:
/// - Calls apply in the order they are made (FIFO): a [read] or [take] reflects every earlier
///   [setText] and [insert], also when those wait for an input method's commit.
/// - [read] and [take] may complete with an error. A caller must not lose the model's draft when
///   they do. Today [ComposerModel] does not catch it: `submit` and `detach` leave the draft as it
///   was (the last copy; `submit` clears it only after a take succeeded), the idle copy keeps the
///   draft it had, and the error is not caught there (it goes on to whoever awaits).
abstract class ComposerEditor {
  /// Set by the panel before the first [view].
  EditorHandlers? handlers;

  /// The editing area; grows from one line (48) up to [maxHeight], then scrolls.
  Widget view(BuildContext context, {required EditorStyle style, required String hint, required double maxHeight});
  void focus();
  void unfocus();

  /// Replaces all text, caret at the end. While composing: applied after the commit.
  void setText(String text);

  /// At the caret (replacing a selection). While composing: applied after the commit.
  void insert(String text);

  /// A copy of the whole text.
  Future<String> read();

  /// The whole text; the editor is empty afterwards. While composing: completes after the commit.
  Future<String> take();
  void dispose();
}
