// The composer's draft for one session (R18): the text with its blocks in it (each a mark where it was
// pasted, [blockMarks]), open or not, and the status line. The runner holds what the blocks stand for and
// does the sending.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'composer_editor.dart';
import 'session_port.dart';

sealed class Submit {}

/// Sending, or an empty Enter within 1 s of a send (W15).
class SubmitNothing extends Submit {}

/// Empty: a Return for A.
class SubmitReturn extends Submit {}

class SubmitPieces extends Submit {
  SubmitPieces(this.pieces);
  final List<Map<String, Object>> pieces;
}

/// One send: what was taken out of the editor, in the editor's order: text runs ([String], never empty)
/// and blocks ([BlockChip]). Each part is one piece.
class Outgoing {
  Outgoing(List<Object> parts) : parts = List.unmodifiable(parts) {
    assert(parts.every((p) => p is BlockChip || (p is String && p.isNotEmpty)));
  }
  final List<Object> parts;

  /// The blocks among [parts], in order.
  List<BlockChip> get blocks => [for (final p in parts) if (p is BlockChip) p];

  /// The text runs joined (a record's text, a row's first line).
  String get text => parts.whereType<String>().join();

  /// When it was handed off (set by `submit` and `retry`).
  DateTime? at;

  /// Leading pieces that went.
  int sent = 0;

  /// Null while in flight.
  String? failure;

  List<Map<String, Object>> pieces() => [
        for (final p in parts) p is BlockChip ? {'block': p.n} : {'text': p as String},
      ];

  /// [pieces] minus the first [sent].
  List<Map<String, Object>> remaining() => pieces().skip(sent).toList();
}

/// macOS virtual key code of Return, what the after-send step presses.
const returnKeyCode = 36;

/// macOS virtual key code of Esc.
const escKeyCode = 53;

class ComposerModel extends ChangeNotifier {
  /// [onDrop]: a block left the composer (removed, or sent); the runner forgets what it held.
  /// [onAllSent]: a send round put every piece into A (not partial, failed or cancelled).
  ComposerModel({this.onDrop, this.onAllSent, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final void Function(int n)? onDrop;
  final VoidCallback? onAllSent;
  final DateTime Function() _clock;

  /// Called when [draft] becomes a different text; with [draftText] (no block marks: the blocks do
  /// not outlive the session).
  ValueChanged<String>? onDraftChanged;

  /// Called when a send hands [o] off (`submit`, and `retry` with the same one), while [draft]
  /// still holds its text.
  void Function(Outgoing o)? onSubmitted;

  /// Called once per send round after `done` updated `o.sent`; [all]: everything went by now.
  void Function(Outgoing o, {required bool all})? onFinished;

  /// The text while no editor is attached; the last copy otherwise. A held block is in it as its mark.
  String get draft => _draft;
  String _draft = '';
  int _draftEpoch = 0;
  set draft(String v) {
    _draftEpoch++;
    if (_draft == v) return;
    _draft = v;
    onDraftChanged?.call(_plain(v));
  }

  /// [draft] without the marks of the blocks held: what a record keeps.
  String get draftText => _plain(_draft);

  ComposerEditor? _editor;
  Future<void>? _detaching;
  Future<void>? _attached;
  Timer? _idleTimer;

  /// Set by the panel from the editor's onFocus.
  bool editorFocused = false;

  /// The blocks the draft holds, in the order they came; each stands in the text as its mark. One deleted
  /// from the text (Backspace) stays held while an undo can bring it back: until the next send, detach
  /// or [setDraft], which drop it in the runner.
  final List<BlockChip> blocks = [];

  /// Block number → its mark (a unit of [blockMarks]), for each of [blocks].
  final Map<int, int> _marks = {};
  bool _inlineDetachedDraft = false;

  List<BlockChip> get nativeBlocks => [for (final b in blocks)
    BlockChip(b.n, b.label, mark: _marks[b.n], kind: b.kind, bytes: b.bytes, text: b.text, name: b.name)];

  /// Holds [b] and gives its mark; null (and [b] dropped) when every mark is in use. [beside] is text
  /// going in with it.
  int? _hold(BlockChip b, [String beside = '']) {
    final had = _marks[b.n];
    if (had != null) return had;
    // Nor one the text has as a plain character (a pasted icon glyph): it would turn into this chip.
    final used = {..._marks.values, ..._draft.codeUnits, ...beside.codeUnits};
    for (final u in blockMarks) {
      if (used.contains(u)) continue;
      blocks.add(b);
      return _marks[b.n] = u;
    }
    onDrop?.call(b.n);
    _show('块太多，${b.label} 没有放进去', const Duration(seconds: 5));
    return null;
  }

  /// [s] without the marks of the blocks held.
  String plainText(String s) => _plain(s);

  String _plain(String s) {
    if (_marks.isEmpty) return s;
    final marks = _marks.values.toSet();
    return String.fromCharCodes(s.codeUnits.where((u) => !marks.contains(u)));
  }

  /// [text] cut at the marks of the blocks held: text runs and blocks, in order. A second mark of one
  /// block is left out (the runner sends a block once).
  List<Object> _parts(String text) {
    final byMark = {for (final b in blocks) _marks[b.n]!: b};
    final out = <Object>[];
    final seen = <int>{};
    void add(String t) {
      if (t.isEmpty) return;
      if (out.isNotEmpty && out.last is String) {
        out.last = (out.last as String) + t;
      } else {
        out.add(t);
      }
    }

    var start = 0;
    for (var i = 0; i < text.length; i++) {
      final b = byMark[text.codeUnitAt(i)];
      if (b == null) continue;
      add(text.substring(start, i));
      start = i + 1;
      if (seen.add(b.n)) out.add(b);
    }
    add(text.substring(start));
    return out;
  }

  /// Lets go of every held block; those not in [kept] leave the runner too.
  void _release({Set<int> kept = const {}}) {
    for (final b in blocks) {
      if (!kept.contains(b.n)) onDrop?.call(b.n);
    }
    blocks.clear();
    _marks.clear();
  }

  /// Lets go of the held blocks whose mark [text] no longer has (no undo can bring them back now).
  void _dropMissing(String text) {
    final units = text.codeUnits.toSet();
    final gone = [for (final b in blocks) if (!units.contains(_marks[b.n])) b];
    for (final b in gone) {
      blocks.remove(b);
      _marks.remove(b.n);
      onDrop?.call(b.n);
    }
  }

  /// The editor learns the chips' labels before text with their marks comes in.
  void _showChips(ComposerEditor e) => e.chips({for (final b in blocks) _marks[b.n]!: b.label});

  bool _open = false;
  bool get open => _open;
  set open(bool v) => _setOpen(v, byLetter: false);

  /// Opens the panel for a typed letter (type-to-compose); [openedByLetter] until it closes or sends.
  void openByLetter() => _setOpen(true, byLetter: true);

  void _setOpen(bool v, {required bool byLetter}) {
    if (_open == v) return;
    _open = v;
    if (v) {
      _letterOpenAt = byLetter ? _clock() : null;
      _toCheck = null;
    } else if (_letterOpenAt != null) {
      _toCheck = _letterOpenAt;
      _letterOpenAt = null;
      // With an editor the check waits for [detach], which brings its text into [draft].
      if (_editor == null) _checkDeclined();
    }
    notifyListeners();
  }

  /// When a letter opened the panel, while it is open and nothing has been sent from it.
  DateTime? _letterOpenAt;

  /// A letter-opened panel closed: when it opened, until [_checkDeclined] has looked at its text.
  DateTime? _toCheck;

  /// This open was a typed letter's, not the user's own (button, key, a clip's 「插入」).
  bool get openedByLetter => _letterOpenAt != null;

  /// A letter-opened panel was closed unused (see [_unused]): the user meant the app's own keys, so letters
  /// stop opening the panel until they open it themselves.
  VoidCallback? onDeclined;

  /// A close this soon after the letter (Esc right away) leaves any ASCII text unused.
  static const _declineWithin = Duration(seconds: 3);

  /// The most letters the panel can hold from the picture (typed before it took the caret): a later close
  /// with no more than these was not written in.
  static const _heldLetters = 3;

  /// Nothing sent (else no check), no chips, ASCII only, and either just the held letters or a quick close.
  bool _unused(String t, DateTime openedAt) {
    if (t.runes.any((r) => r >= 128)) return false; // a block's mark is not ASCII either
    final s = t.trim();
    return (s.length <= _heldLetters && !s.contains(' ')) || _clock().difference(openedAt) < _declineWithin;
  }

  void _checkDeclined() {
    final at = _toCheck;
    if (at == null) return;
    _toCheck = null;
    if (!_unused(_draft, at)) return;
    draft = ''; // the held letters were never for the panel
    onDeclined?.call();
  }

  /// A send round is running (from `submit()` until `done`).
  bool sending = false;

  /// A short note on the hint line above the box (W11); clears by itself.
  String? status;

  Outgoing? _inFlight;
  Outgoing? get inFlight => _inFlight;
  final List<Outgoing> _failed = [];
  List<Outgoing> get failed => List.unmodifiable(_failed);

  Timer? _statusTimer;
  bool _copyPending = false;
  bool _disposed = false;
  bool _taking = false;

  /// A send is waiting for the editor's text (an input method still composing).
  bool get taking => _taking;
  DateTime? _lastSend;

  void _setTaking(bool on) {
    _taking = on;
    if (!_disposed) notifyListeners();
  }

  /// The editor takes over; it starts with [draft].
  Future<void> attach(ComposerEditor e) {
    _editor = e;
    final previous = _detaching;
    if (previous == null) {
      _start(e);
      _attached = null;
      return SynchronousFuture<void>(null);
    }
    // A native read may finish after the next panel mounts. Restore only after that read,
    // before the new editor takes focus; otherwise reopening can resurrect an older draft.
    return _attached = previous.then((_) => _start(e));
  }

  /// The editor takes the draft: its chips, then the text with their marks in it.
  void _start(ComposerEditor e) {
    if (_inlineDetachedDraft) {
      _dropMissing(draft);
      _inlineDetachedDraft = false;
    } else {
      _restoreMarks();
    }
    _showChips(e);
    e.setText(draft);
  }

  /// A detached native composer's text has no marks in it (its chips are held here). Put the marks of
  /// the blocks still held back at the end, so the editor can show them and a read cannot drop them.
  void _restoreMarks() {
    if (blocks.isEmpty) return;
    final units = _draft.codeUnits.toSet();
    final missing = [for (final b in blocks) if (!units.contains(_marks[b.n])) _marks[b.n]!];
    if (missing.isEmpty) return;
    draft = _draft + String.fromCharCodes(missing);
  }

  /// The editor goes away: its text is copied into [draft]. It no longer has the focus (its
  /// dispose drops the focus listener first, so no onFocus(false) comes).
  Future<void> detach(ComposerEditor e) {
    if (!identical(_editor, e)) return Future.value();
    _editor = null;
    editorFocused = false;
    _idleTimer?.cancel();
    final ready = _attached;
    final epoch = _draftEpoch;
    Future<void> copy() async {
      final text = await e.read();
      // Assigning draft bumps the epoch, so decide before the write whether this read is still ours.
      final mine = _draftEpoch == epoch;
      if (mine) draft = text;
      if (_disposed) return;
      if (mine) _dropMissing(draft); // the editor's undo goes with it
      _checkDeclined();
    }
    final work = ready == null ? copy() : ready.then((_) => copy());
    late final Future<void> pending;
    pending = work.whenComplete(() {
      if (identical(_detaching, pending)) _detaching = null;
    });
    return _detaching = pending;
  }

  /// Stop user input before reading; the two editors must never both accept edits.
  void handoff(bool active) {
    final e = _editor;
    if (e is HandoffEditor) (e as HandoffEditor).setHandoff(active);
  }

  Future<void>? _inserting;

  /// Clipboard/file-picker results belong to the draft even across a window handoff.
  /// Preserve request order and let the handoff wait until they are reflected in the editor.
  Future<void> applyPending(Future<PasteResult> result) {
    final previous = _inserting;
    final work = () async {
      if (previous != null) await previous.catchError((Object _) {});
      apply(await result);
    }();
    late final Future<void> pending;
    pending = work.whenComplete(() {
      if (identical(_inserting, pending)) _inserting = null;
    });
    return _inserting = pending;
  }

  /// Flush the current editor before handing the draft to a native detached window.
  Future<String> readDraft({bool inline = false}) async {
    await _inserting;
    await _attached;
    await _detaching;
    final e = _editor;
    final epoch = _draftEpoch;
    if (e != null) {
      final text = await e.read();
      if (identical(_editor, e) && _draftEpoch == epoch && !_disposed) draft = text;
    }
    return inline ? draft : draftText;
  }

  /// Native text updates keep held blocks until submission or handoff, so native undo can restore
  /// deleted anchors. Legacy native editors send plain text and report chip removals separately.
  void setDetachedDraft(String s, {bool inline = false}) {
    _inlineDetachedDraft = inline;
    draft = s;
    _editor?.setText(s);
  }

  /// Replaces the text: into the editor if attached, else the draft. Held blocks [s] has no mark of are
  /// dropped.
  void setDraft(String s) {
    _inlineDetachedDraft = false;
    _dropMissing(s);
    draft = s;
    _editor?.setText(s);
  }

  /// A chip tapped away in a native or detached composer (a draft event's `drop`): that block goes, and
  /// its mark leaves the text. Only that block — [draft] can be a copy behind the attached editor's text,
  /// so the other blocks' marks are never judged by it here (that is [_dropMissing]'s job, on a read).
  void removeBlock(int n) {
    final mark = _marks.remove(n);
    if (mark == null) return;
    blocks.removeWhere((b) => b.n == n);
    onDrop?.call(n); // the other window has no undo: the runner can forget it now
    final s = String.fromCharCode(mark);
    if (_draft.contains(s)) draft = _draft.replaceAll(s, '');
    final e = _editor;
    if (e != null) unawaited(_stripMark(e, s));
    notifyListeners();
  }

  /// Takes [mark] out of the attached editor's text, which the draft copy can be behind.
  Future<void> _stripMark(ComposerEditor e, String mark) async {
    final text = await e.read();
    if (_disposed || !identical(_editor, e) || !text.contains(mark)) return;
    final stripped = text.replaceAll(mark, '');
    draft = stripped;
    e.setText(stripped);
  }

  /// The editor's text changed: 1 s after the last change it is copied into [draft].
  void editorChanged() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 1), () async {
      final e = _editor;
      if (e == null || _disposed) return;
      final t = await e.read();
      if (identical(_editor, e) && !_disposed) draft = t;
    });
  }

  /// Text at the caret, or at the end of the draft without an editor. Marks in it stand for the
  /// blocks held.
  void insert(String s) {
    final e = _editor;
    if (e != null) {
      _showChips(e);
      e.insert(s);
    } else {
      draft += s;
    }
  }

  /// Bumped when the panel should unfocus the editor (W8).
  int releaseTick = 0;
  void releaseFocus() {
    releaseTick++;
    notifyListeners();
  }

  /// Closes the panel; the text stays (W6).
  void collapse() => open = false;

  /// The user pressed send (or Enter): takes the text with its blocks out of the composer.
  Future<Submit> submit() async {
    if (sending || _taking) return SubmitNothing();
    _letterOpenAt = null; // sent: the panel was wanted
    _toCheck = null;
    _idleTimer?.cancel();
    _setTaking(true);
    final String text;
    try {
      final e = _editor;
      if (e != null) {
        text = await e.take();
      } else {
        text = draft;
      }
    } finally {
      _setTaking(false);
    }
    if (_disposed) return SubmitNothing();
    if (sending || _inFlight != null) {
      // Another round started while the take waited: the text goes back, nothing is sent twice.
      if (_editor != null) draft = '';
      if (text.isNotEmpty) insert(text);
      return SubmitNothing();
    }
    final now = _clock();
    final parts = _parts(text);
    if (parts.isEmpty) {
      _release();
      draft = '';
      final last = _lastSend;
      if (last != null && now.difference(last) < const Duration(seconds: 1)) return SubmitNothing();
      return SubmitReturn();
    }
    _lastSend = now;
    final o = Outgoing(parts)..at = now;
    onSubmitted?.call(o);
    draft = '';
    // The row holds them now; the ones deleted from the text leave the runner.
    _release(kept: {for (final b in o.blocks) b.n});
    _inFlight = o;
    sending = true;
    notifyListeners();
    return SubmitPieces(o.pieces());
  }

  /// The runner's `sending`; a stop before `done` is held until `done` comes.
  void setSending(bool on) {
    if (!on && _inFlight != null) return;
    if (sending == on) return;
    sending = on;
    notifyListeners();
  }

  /// A send round ended: the first [sent] pieces of it went. What did not go stays as a failed
  /// item; [failure] says why. Empty (cancelled, or an upload that failed: the runner cannot tell
  /// them apart) and null (the link dropped) both read 「没有发出去」.
  void done(int sent, String? failure) {
    final o = _inFlight;
    _inFlight = null;
    sending = false;
    _lastSend = _clock();
    if (o == null) {
      notifyListeners();
      return;
    }
    final total = o.pieces().length;
    final before = o.sent;
    final after = (before + (sent < 0 ? 0 : sent)).clamp(0, total);
    o.sent = after;
    for (final p in o.parts.sublist(before, after)) {
      if (p is BlockChip) onDrop?.call(p.n);
    }
    final all = after >= total;
    if (!all) {
      o.failure = (failure != null && failure.isNotEmpty) ? failure : '没有发出去';
      _failed.add(o);
    } else if (failure != null) {
      o.failure = failure; // all went, but the round said something: no after-send step
    }
    notifyListeners();
    onFinished?.call(o, all: all);
    if (all && failure == null) onAllSent?.call();
  }

  /// Sends what is left of [o] again: the pieces for the runner, or null while sending or while a
  /// send waits for its take.
  List<Map<String, Object>>? retry(Outgoing o) {
    if (sending || _taking || !_failed.remove(o)) return null;
    o.failure = null;
    o.at = _clock();
    _inFlight = o;
    sending = true;
    notifyListeners();
    onSubmitted?.call(o);
    return o.remaining();
  }

  /// A reconnect's swap: [old] was this window's session before. Its draft and the unsent text of
  /// its failed rows and of its in-flight row come over, all as failed rows (the in-flight one never
  /// got its `done`). Blocks stay behind (the old runner held them): their marks leave the draft, a
  /// row's text runs join up, and a row without text does not come. With [old]'s editor still
  /// attached, its text is read for the draft. Returns each of [old]'s rows that came over with the
  /// row made for it, in order.
  Map<Outgoing, Outgoing> adoptFrom(ComposerModel old) {
    final made = <Outgoing, Outgoing>{
      for (final o in [...old._failed, ?old._inFlight])
        if (o.parts.skip(o.sent).whereType<String>().join() case final t when t.isNotEmpty)
          o: Outgoing([t])..failure = o.failure ?? '没有发出去',
    };
    _failed.insertAll(0, made.values);
    if (draft.isEmpty) draft = old.draftText;
    final e = old._editor;
    if (e != null) {
      final before = draft;
      e.read().then((t) {
        // Only while nothing here moved on (the new panel attaches a frame later).
        if (!_disposed && _editor == null && draft == before) draft = old._plain(t);
      }, onError: (Object _) {});
    }
    notifyListeners();
    return made;
  }

  /// [o] goes back into the composer: what did not go, at the caret, in its order.
  void putBack(Outgoing o) {
    if (!_failed.remove(o)) return;
    final s = StringBuffer();
    for (final p in o.parts.skip(o.sent)) {
      if (p is BlockChip) {
        final m = _hold(p, s.toString());
        if (m != null) s.writeCharCode(m);
      } else {
        s.write(p);
      }
    }
    if (s.isNotEmpty) insert(s.toString());
    notifyListeners();
  }

  /// Bumped by [requestPaste]; the panel runs its own paste for each bump it has not taken yet.
  int pasteTick = 0;
  int _pasteTaken = 0;

  /// The panel should paste from the clipboard (K4: several lines pasted on a terminal's stage), also when
  /// it is only about to be shown.
  void requestPaste() {
    pasteTick++;
    notifyListeners();
  }

  /// For the panel: whether a [requestPaste] waits; it is taken once.
  bool takePaste() {
    if (_pasteTaken == pasteTick) return false;
    _pasteTaken = pasteTick;
    return true;
  }

  /// Bumped when the field should take the caret (a clip's 「插入」); the panel follows it.
  int focusTick = 0;

  /// The field should take the caret, even from a focused picture.
  void wantFocus() {
    focusTick++;
    notifyListeners();
  }

  /// A compose letter is held by the runner (type-to-compose): once the field has the caret, the panel asks
  /// for it back ([takeReplay]).
  bool replayPending = false;

  /// True once per held compose letter.
  bool takeReplay() {
    if (!replayPending) return false;
    replayPending = false;
    return true;
  }

  /// 「复制」 was pressed (the caller sent ⌘C to A): A's clipboard should change within 2 s.
  void copyPressed() {
    _copyPending = true;
    status = '已复制';
    _statusTimer?.cancel();
    _statusTimer = Timer(const Duration(seconds: 2), () {
      if (!_copyPending) return;
      _copyPending = false;
      _show('远端没有复制到东西', const Duration(seconds: 2));
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

  /// A paste, attach or insert result at the caret: its text, then its blocks as chips; a status shown.
  /// Ignored once the session is gone (a runner answer can come after).
  void apply(PasteResult r) {
    if (_disposed) return;
    // Pasted text never carries a held block's mark: it would stand for that block a second time.
    final s = StringBuffer(_plain(r.text ?? ''));
    for (final b in r.blocks) {
      final m = _hold(b, s.toString());
      if (m != null) s.writeCharCode(m);
    }
    if (s.isNotEmpty) insert(s.toString());
    final status = r.status;
    if (status != null) _show(status, const Duration(seconds: 5));
    notifyListeners();
  }

  /// A short note on the hint line above the box for a few seconds.
  void note(String s) {
    _show(s, const Duration(seconds: 4));
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
    _idleTimer?.cancel();
    super.dispose();
  }
}
