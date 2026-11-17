// A terminal session as a SessionPort: the local worker's wire protocol instead of the runner's channel.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard;

import '../embed/session_port.dart';
import 'term_link.dart';
import 'term_model.dart';
import 'term_wire.dart';

/// The most one paste may be, in UTF-8 bytes (`MAX_PASTE` in the worker).
const int maxPaste = 1048576;

const pasteTooLong = '太长了：终端一次最多贴 1 MiB';
const termNoAttach = '终端会话不支持';
const termNoText = '剪贴板里没有文字：终端会话不能贴图片或文件';
const pasteFailed = '没有贴进去';
const linkGone = '连接断了';

/// The writing panel's paste rule (W14): under 800 characters and under 10 lines goes in as text, else a block.
bool pastesInline(String text) => text.runes.length < 800 && '\n'.allMatches(text).length + 1 < 10;

/// macOS key codes the writing panel sends -> the worker's key names.
const _keyNames = {
  36: 'Enter', 53: 'Esc', 48: 'Tab', 51: 'Backspace', 123: 'Left', 124: 'Right', 125: 'Down', 126: 'Up',
  116: 'PageUp', 121: 'PageDown',
};

class _Paste {
  _Paste(this.lines);
  final List<String> lines;
  final done = Completer<String?>();
}

class _Term {
  _Term(this.sid, this.model);
  final Object sid;
  final TermModel model;
  TermLink? link;
  Timer? traffic;
  List<TermPane> panes = const [];
  bool ready = false;
  bool closed = false;
  bool disconnected = false;
  int screens = 0;

  /// The `hello` version; 0 until it comes.
  int v = 0;

  /// Pastes in the order made: the first is out and waits for its `pasted`, the rest wait their turn.
  final pastes = Queue<_Paste>();

  /// The latest view asked for, and whether this connection has been sent it.
  ({String pane, int cols, int rows, bool fit})? view;
  bool viewSent = false;
}

class TermSessionPort extends SessionPort {
  TermSessionPort(
      {Dial? dial,
      Duration trafficEvery = const Duration(seconds: 1)})
      // ignore: prefer_initializing_formals
      : _dial = dial,
        // ignore: prefer_initializing_formals
        _trafficEvery = trafficEvery;

  final Dial? _dial;
  final Duration _trafficEvery;

  final _events = StreamController<SessionEvent>.broadcast();
  final _terms = <Object, _Term>{};
  bool _disposed = false;

  /// The writing panel's text blocks, per session: their text by block number.
  final _blocks = <Object, Map<int, String>>{};
  final _lastBlock = <Object, int>{};

  @override
  bool get supportsDetach => false;
  @override
  Stream<SessionEvent> get events => _events.stream;

  @protected
  void emit(SessionEvent e) {
    if (!_disposed) _events.add(e);
  }

  bool owns(Object sid) => _terms.containsKey(sid);
  TermModel? model(Object sid) => _terms[sid]?.model;
  List<TermPane> panes(Object sid) => _terms[sid]?.panes ?? const [];

  TermPane? pane(Object sid, int window) {
    for (final p in panes(sid)) {
      if (p.number == window) return p;
    }
    return null;
  }

  /// The latest view's columns and rows sent to any terminal.
  int? lastCols, lastRows;

  @override
  void dispose() {
    _disposed = true;
    for (final t in _terms.values) {
      _stop(t);
    }
    _terms.clear();
    _events.close();
  }

  @override
  Future<Object?> invoke(String method, Map<String, Object?> args) async {
    final sid = args['sid'];
    if (sid == null) return null;
    switch (method) {
      case 'start':
        await _start(sid, args['port'] as int, args['token'] as String);
      case 'close':
        _blocks.remove(sid);
        _lastBlock.remove(sid);
        final t = _terms.remove(sid);
        if (t == null) return null;
        _stop(t);
        emit(ClosedEvent(sid, 'closed'));
    }
    return null;
  }

  void _stop(_Term t) {
    t.closed = true;
    t.traffic?.cancel();
    t.link?.close();
    _endWaiting(t);
  }

  /// What still waits on the device's answer ends: the connection is gone.
  void _endWaiting(_Term t) {
    while (t.pastes.isNotEmpty) {
      t.pastes.removeFirst().done.complete(linkGone);
    }
  }

  Future<void> _start(Object sid, int port, String token) async {
    // A sid is started once: a reconnect is a new sid with a new model, and the TermStage put up for it asks for
    // the view again. A second start of the same sid only replaces the first connection.
    final old = _terms[sid];
    if (old != null) _stop(old);
    final t = _Term(sid, TermModel());
    _terms[sid] = t;
    final TermLink link;
    try {
      link = await TermLink.connect(port, token, dial: _dial);
    } catch (_) {
      if (identical(_terms[sid], t)) _terms.remove(sid);
      rethrow;
    }
    if (t.closed) {
      link.close();
      throw StateError('Session start cancelled');
    }
    t.link = link;
    // A view asked for while connecting goes out now.
    final v = t.view;
    if (v != null) _sendView(t, v);
    t.traffic = Timer.periodic(_trafficEvery, (_) {
      final screens = t.screens;
      t.screens = 0;
      emit(TrafficEvent(sid, link.takeBytes(), screens));
    });
    link.messages.listen((m) => _onMessage(t, m));
    unawaited(link.done.then((_) {
      // The words a dropped app session's link ends with: the lifecycle tries again by itself.
      if (!t.closed) _lost(t, 'connection closed');
    }));
  }

  void _lost(_Term t, String reason) {
    if (t.closed || t.disconnected) return;
    t.disconnected = true;
    t.traffic?.cancel();
    t.link?.close();
    _endWaiting(t);
    emit(DisconnectedEvent(t.sid, reason));
  }

  void _onMessage(_Term t, TermOut m) {
    // Lines read before `session ended` (or the link going) can still be queued: the session is over for them.
    if (t.closed || t.disconnected) return;
    switch (m) {
      case TermPanes():
        t.panes = m.panes;
        final labels = tabLabels(m.panes);
        emit(WindowsEvent(t.sid, [
          for (final p in m.panes)
            RemoteWindow(
              id: p.number,
              parent: 0,
              kind: WindowKind.normal,
              title: labels[p.id] ?? p.command,
              rect: Rect.zero,
              titleBar: 0,
              resizable: false,
              focused: p.active,
              texture: null,
              visible: Rect.zero,
            ),
        ]));
        if (!t.ready) {
          t.ready = true;
          final cur = m.panes.where((p) => p.active).firstOrNull ?? m.panes.firstOrNull;
          emit(ReadyEvent(t.sid, cur?.command ?? ''));
        }
      case TermScreen():
        if (!m.more) t.screens++;
        final rev = t.model.apply(m);
        if (rev != null) t.link?.send(ackMsg(rev));
      case TermHistory():
        t.model.applyHistory(m);
        fetchHistory(t.sid);
      case TermError():
        if (m.error == 'session ended') {
          _lost(t, 'session ended');
        } else {
          t.model.fail(m.error);
        }
      case TermHello():
        t.v = m.v;
      case TermPasted():
        if (t.pastes.isEmpty) return;
        t.pastes.removeFirst().done.complete(m.ok ? null : (m.error ?? pasteFailed));
        if (t.pastes.isNotEmpty) _sendPaste(t, t.pastes.first);
    }
  }

  bool _live(_Term t) => t.link != null && !t.disconnected && !t.closed;

  /// The pane being viewed, when input can go to it now: connected, and the pane not exited.
  String? _target(_Term t) {
    final id = t.view?.pane;
    if (id == null || !_live(t)) return null;
    if (t.panes.any((p) => p.id == id && p.dead)) return null;
    return id;
  }

  /// Sends key names to the pane being viewed; nothing (and nothing kept) when it has exited or the link is down.
  void sendKeys(Object sid, List<String> keys) {
    final t = _terms[sid];
    final pane = t == null ? null : _target(t);
    if (pane == null || keys.isEmpty) return;
    t!.link!.sendLine(keysMsg(pane, keys));
  }

  /// Types literal [text] into the pane being viewed, like [sendKeys].
  void type(Object sid, String text) {
    final t = _terms[sid];
    final pane = t == null ? null : _target(t);
    if (pane == null || text.isEmpty) return;
    t!.link!.sendLine(typeMsg(pane, text));
  }

  /// Only the keys the writing panel sends (macOS key codes); the modifiers are not used.
  @override
  void key(Object sid, int keyCode, int modifiers) {
    final name = _keyNames[keyCode];
    if (name != null) sendKeys(sid, [name]);
  }

  /// Pastes [data] into the pane being viewed now, even if another is viewed before it goes out. Null when it is
  /// in; otherwise why not. Pastes on one connection go one at a time, in order.
  Future<String?> paste(Object sid, String data, {bool enter = false}) {
    if (utf8.encode(data).length > maxPaste) return Future.value(pasteTooLong);
    final t = _terms[sid];
    if (t == null || !_live(t)) return Future.value(linkGone);
    final pane = _target(t);
    if (pane == null) return Future.value(pasteFailed);
    final p = _Paste(textMsgs(pane, data, enter: enter));
    t.pastes.add(p);
    if (t.pastes.length == 1) _sendPaste(t, p);
    return p.done.future;
  }

  void _sendPaste(_Term t, _Paste p) {
    for (final l in p.lines) {
      t.link!.sendLine(l);
    }
  }

  /// The writing panel's ⌘V: the clipboard's text by W14, a long one as a block this port keeps until dropped.
  @override
  Future<PasteResult> composerPaste(Object sid) async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      return const PasteResult(); // no clipboard to read: nothing
    }
    // Flutter reads text only: a clipboard without any is an image or files (or nothing), which a
    // terminal cannot take. Said, so the paste does not look ignored.
    if (text == null || text.isEmpty) return const PasteResult(status: termNoText);
    if (pastesInline(text)) return PasteResult(text: text);
    final n = (_lastBlock[sid] ?? 0) + 1;
    _lastBlock[sid] = n;
    (_blocks[sid] ??= {})[n] = text;
    final lines = '\n'.allMatches(text).length + 1;
    return PasteResult(blocks: [
      BlockChip(n, '[贴入文字 #$n +$lines 行]', kind: 'text', bytes: utf8.encode(text).length, text: text),
    ]);
  }

  @override
  Future<PasteResult> composerAttach(Object sid) async => const PasteResult(status: termNoAttach);

  @override
  void composerDropBlock(Object sid, int block) => _blocks[sid]?.remove(block);

  /// The writing panel's send: its pieces joined in order into one paste (no Return: the after-send step is
  /// the session's). `sending` goes first; `done` when the paste is answered, all of it or none.
  @override
  void composerSend(Object sid, List<Map<String, Object>> pieces) {
    emit(ComposerStateEvent(sid, sending: true));
    final data = StringBuffer();
    String? missing;
    for (final p in pieces) {
      final text = p['text'], block = p['block'];
      if (text is String) {
        data.write(text);
      } else if (block is int && _blocks[sid]?[block] != null) {
        data.write(_blocks[sid]![block]);
      } else {
        missing = pasteFailed;
      }
    }
    void done(String? why) =>
        emit(ComposerStateEvent(sid, sending: false, done: ComposerDone(why == null ? pieces.length : 0, why)));
    if (missing != null) {
      done(missing);
      return;
    }
    paste(sid, data.toString()).then(done, onError: (Object _) => done(pasteFailed));
  }

  /// Shows pane [window] at [cols]x[rows]; with [fit] the host resizes its window to that size.
  /// The same parameters (fit included) are not sent twice on one connection.
  void view(Object sid, int window, int cols, int rows, {bool fit = false}) {
    final t = _terms[sid];
    if (t == null) return;
    final id = pane(sid, window)?.id ?? '%$window';
    final v = (pane: id, cols: cols, rows: rows, fit: fit);
    if (t.viewSent && t.view == v) return;
    t.view = v;
    if (t.link == null || t.disconnected) return;
    _sendView(t, v);
  }

  void _sendView(_Term t, ({String pane, int cols, int rows, bool fit}) v) {
    t.viewSent = true;
    lastCols = v.cols;
    lastRows = v.rows;
    t.model.expect(v.pane);
    t.link!.send(viewMsg(v.pane, v.cols, v.rows, fit: v.fit));
  }

  /// Sends the next history request the model wants, if any.
  void fetchHistory(Object sid) {
    final t = _terms[sid];
    if (t == null || t.disconnected || t.link == null) return;
    final pane = t.model.pane;
    if (pane == null) return;
    final w = t.model.wantHistory();
    if (w == null) return;
    t.link!.send(historyReq(pane, w.before, w.lines));
  }
}
