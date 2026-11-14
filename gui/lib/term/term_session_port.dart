// A terminal session as a SessionPort: the local worker's wire protocol instead of the runner's channel.
import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import '../embed/session_port.dart';
import 'term_link.dart';
import 'term_model.dart';
import 'term_wire.dart';

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

  /// The latest view asked for, and whether this connection has been sent it.
  ({String pane, int cols, int rows})? view;
  bool viewSent = false;
}

class TermSessionPort extends SessionPort {
  TermSessionPort({Dial? dial, Duration trafficEvery = const Duration(seconds: 1)})
      // ignore: prefer_initializing_formals
      : _dial = dial,
        // ignore: prefer_initializing_formals
        _trafficEvery = trafficEvery;

  final Dial? _dial;
  final Duration _trafficEvery;
  final _events = StreamController<SessionEvent>.broadcast();
  final _terms = <Object, _Term>{};
  bool _disposed = false;

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

  @override
  void dispose() {
    _disposed = true;
    for (final t in _terms.values) {
      t.closed = true;
      t.traffic?.cancel();
      t.link?.close();
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
  }

  Future<void> _start(Object sid, int port, String token) async {
    final old = _terms[sid];
    if (old != null) _stop(old);
    // The model stays across a reconnect: the picture rests on the last screen until a new one comes.
    // So does the view: the stage stays as it was and asks nothing new, so the link-up below sends it.
    final t = _Term(sid, old?.model ?? TermModel())
      ..panes = old?.panes ?? const []
      ..view = old?.view;
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
      if (!t.closed) _lost(t, 'connection lost');
    }));
  }

  void _lost(_Term t, String reason) {
    if (t.closed || t.disconnected) return;
    t.disconnected = true;
    t.traffic?.cancel();
    t.link?.close();
    emit(DisconnectedEvent(t.sid, reason));
  }

  void _onMessage(_Term t, TermOut m) {
    if (t.closed) return;
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
      case TermHello() || TermPasted():
        break;
    }
  }

  /// Shows pane [window] at [cols]x[rows]; the same parameters are not sent twice on one connection.
  void view(Object sid, int window, int cols, int rows) {
    final t = _terms[sid];
    if (t == null) return;
    final id = pane(sid, window)?.id ?? '%$window';
    final v = (pane: id, cols: cols, rows: rows);
    if (t.viewSent && t.view == v) return;
    t.view = v;
    if (t.link == null || t.disconnected) return;
    _sendView(t, v);
  }

  void _sendView(_Term t, ({String pane, int cols, int rows}) v) {
    t.viewSent = true;
    t.model.expect(v.pane);
    t.link!.send(viewMsg(v.pane, v.cols, v.rows));
  }

  /// Asks the device to fit the pane to the latest view again.
  void refit(Object sid) {
    final t = _terms[sid], v = t?.view;
    if (t == null || v == null || t.disconnected) return;
    t.link?.send(refitMsg(v.pane, v.cols, v.rows));
  }

  /// Sends the next history request the model wants, if any.
  void fetchHistory(Object sid) {
    final t = _terms[sid];
    if (t == null || t.disconnected || t.link == null) return;
    final pane = t.model.pane;
    final w = t.model.wantHistory();
    if (pane == null || w == null) return;
    t.link!.send(historyReq(pane, w.before, w.lines));
  }
}
