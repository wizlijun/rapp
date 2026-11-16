// The editing area behind the writing panel. The model never holds the text; it copies it out
// through this interface at send, session switch, 1 s idle and collapse (spec §5).
import 'package:flutter/widgets.dart';

/// A pasted block (image, file, long text) stands in the editor's text as one character, at the spot it
/// was pasted, so the text around it keeps its order. One UTF-16 unit: a caret, a selection and a
/// Backspace treat it like a letter. The 32 noncharacters U+FDD0–U+FDEF come first (Unicode keeps them for
/// a program's own use: no pasted text has them); after those, a stretch of the Private Use Area that the
/// icon fonts terminals use (Nerd Fonts 3) leave free. A character there means a block only while the
/// composer holds a block with that mark; otherwise it is plain text.
final blockMarks = List<int>.unmodifiable([
  for (var u = 0xFDD0; u <= 0xFDEF; u++) u,
  for (var u = 0xE900; u <= 0xEA5F; u++) u,
]);

/// What the editor reports; it never carries the text (规格 §5).
/// The writing panel's zoom keys: ⌘= (also ⌘+), ⌘-, ⌘0; Ctrl instead of ⌘ off macOS.
enum ZoomKey { bigger, smaller, reset }

class EditorHandlers {
  const EditorHandlers({
    required this.onChanged,
    required this.onEnter,
    required this.onEscape,
    required this.onPaste,
    required this.onFocus,
    required this.onArrow,
    this.onZoom,
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

  /// ↑ ([up]) with the caret on the first line, or ↓ on the last, no modifier, not while
  /// composing. true: the key is taken; false: the caret moves as usual.
  final bool Function(bool up) onArrow;

  /// ⌘= / ⌘- / ⌘0 (Ctrl elsewhere) with the caret here.
  final ValueChanged<ZoomKey>? onZoom;
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

  /// The chips' labels by mark (a UTF-16 unit from [blockMarks]), replacing the ones before. Each
  /// mark in the text with a label shows as a chip with it; given before the [setText] or [insert]
  /// that brings the mark in. [read] and [take] give a chip back as its mark.
  void chips(Map<int, String> labels);

  /// Replaces all text, caret at the end. While composing: applied after the commit.
  void setText(String text);

  /// At the caret (replacing a selection). While composing: applied after the commit.
  void insert(String text);

  /// A copy of the whole text.
  Future<String> read();

  /// No text, now (with every earlier [setText] and [insert] applied). Only for deciding on a
  /// key the editor reports; it says nothing of what the text is.
  bool get isEmpty;

  /// The whole text; the editor is empty afterwards. While composing: completes after the commit.
  Future<String> take();
  void dispose();
}
