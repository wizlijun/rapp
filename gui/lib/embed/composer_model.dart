// The composer's draft for one session (R18): the text, the block chips, open or not, and the
// status line. The runner holds what the blocks stand for and does the sending.
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

/// One send: the blocks and text that were taken out of the editor.
class Outgoing {
  Outgoing(this.blocks, this.text);
  final List<BlockChip> blocks;
  final String text;

  /// When it was handed off (set by `submit` and `retry`).
  DateTime? at;

  /// Pieces that went (blocks first, then text).
  int sent = 0;

  /// Null while in flight.
  String? failure;

  List<Map<String, Object>> pieces() => [
        for (final b in blocks) {'block': b.n},
        if (text.isNotEmpty) {'text': text},
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

  /// Called when [draft] becomes a different text.
  ValueChanged<String>? onDraftChanged;

  /// Called when a send hands [o] off (`submit`, and `retry` with the same one), while [draft]
  /// still holds its text.
  void Function(Outgoing o)? onSubmitted;

  /// Called once per send round after `done` updated `o.sent`; [all]: everything went by now.
  void Function(Outgoing o, {required bool all})? onFinished;

  /// The text while no editor is attached; the last copy otherwise.
  String get draft => _draft;
  String _draft = '';
  set draft(String v) {
    if (_draft == v) return;
    _draft = v;
    onDraftChanged?.call(v);
  }

  ComposerEditor? _editor;
  Future<void>? _detaching;
  Future<void>? _attached;
  Timer? _idleTimer;

  /// Set by the panel from the editor's onFocus.
  bool editorFocused = false;

  /// The chips, in the order they were added.
  final List<BlockChip> blocks = [];

  bool _open = false;
  bool get open => _open;
  set open(bool v) {
    if (_open == v) return;
    _open = v;
    notifyListeners();
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
      e.setText(draft);
      _attached = null;
      return SynchronousFuture<void>(null);
    }
    // A native read may finish after the next panel mounts. Restore only after that read,
    // before the new editor takes focus; otherwise reopening can resurrect an older draft.
    return _attached = previous.then((_) => e.setText(draft));
  }

  /// The editor goes away: its text is copied into [draft]. It no longer has the focus (its
  /// dispose drops the focus listener first, so no onFocus(false) comes).
  Future<void> detach(ComposerEditor e) {
    if (!identical(_editor, e)) return Future.value();
    _editor = null;
    editorFocused = false;
    _idleTimer?.cancel();
    final ready = _attached;
    Future<void> copy() async {
      draft = await e.read();
    }
    final work = ready == null ? copy() : ready.then((_) => copy());
    late final Future<void> pending;
    pending = work.whenComplete(() {
      if (identical(_detaching, pending)) _detaching = null;
    });
    return _detaching = pending;
  }

  /// Replaces the text: into the editor if attached, else the draft.
  void setDraft(String s) {
    draft = s;
    _editor?.setText(s);
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

  /// Text at the caret, or at the end of the draft without an editor.
  void insert(String s) {
    final e = _editor;
    if (e != null) {
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

  /// The user pressed send (or Enter): takes the blocks and the text out of the composer.
  Future<Submit> submit() async {
    if (sending || _taking) return SubmitNothing();
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
    if (sending || _inFlight != null) {
      // Another round started while the take waited: the text goes back, nothing is sent twice.
      if (_editor != null) draft = '';
      if (text.isNotEmpty) insert(text);
      return SubmitNothing();
    }
    final now = _clock();
    if (blocks.isEmpty && text.isEmpty) {
      draft = '';
      final last = _lastSend;
      if (last != null && now.difference(last) < const Duration(seconds: 1)) return SubmitNothing();
      return SubmitReturn();
    }
    _lastSend = now;
    final o = Outgoing(List.of(blocks), text)..at = now;
    onSubmitted?.call(o);
    draft = '';
    blocks.clear();
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
    final dropTo = after < o.blocks.length ? after : o.blocks.length;
    for (var i = before; i < dropTo; i++) {
      onDrop?.call(o.blocks[i].n);
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

  /// A reconnect's swap: [old] was this window's session before. Its draft and the text of its
  /// failed rows and of its in-flight row come over, all as failed rows (the in-flight one never
  /// got its `done`). Blocks stay behind (the old runner held them); a row without text does not
  /// come. With [old]'s editor still attached, its text is read for the draft. Returns each of
  /// [old]'s rows that came over with the row made for it, in order.
  Map<Outgoing, Outgoing> adoptFrom(ComposerModel old) {
    final made = <Outgoing, Outgoing>{
      for (final o in [...old._failed, ?old._inFlight])
        if (o.text.isNotEmpty) o: Outgoing(const [], o.text)..failure = o.failure ?? '没有发出去',
    };
    _failed.insertAll(0, made.values);
    if (draft.isEmpty) draft = old.draft;
    final e = old._editor;
    if (e != null) {
      final before = draft;
      e.read().then((t) {
        // Only while nothing here moved on (the new panel attaches a frame later).
        if (!_disposed && _editor == null && draft == before) draft = t;
      }, onError: (Object _) {});
    }
    notifyListeners();
    return made;
  }

  /// [o] goes back into the composer: unsent blocks in front, unsent text at the caret.
  void putBack(Outgoing o) {
    if (!_failed.remove(o)) return;
    blocks.insertAll(0, o.blocks.skip(o.sent));
    if (o.sent <= o.blocks.length && o.text.isNotEmpty) insert(o.text);
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

  /// A paste, attach or insert result: text at the cursor, blocks as chips, a status shown.
  /// Ignored once the session is gone (a runner answer can come after).
  void apply(PasteResult r) {
    if (_disposed) return;
    final t = r.text;
    if (t != null && t.isNotEmpty) insert(t);
    blocks.addAll(r.blocks);
    final s = r.status;
    if (s != null) _show(s, const Duration(seconds: 5));
    notifyListeners();
  }

  /// The user tapped chip [n] away.
  void removeBlock(int n) {
    final i = blocks.indexWhere((b) => b.n == n);
    if (i < 0) return;
    blocks.removeAt(i);
    onDrop?.call(n);
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
