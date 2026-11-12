import 'dart:async';
import 'dart:convert';

import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';

/// In-memory stand-in for the rapp-hub process.
class FakeTransport implements HubTransport {
  final _out = StreamController<String>();
  final sent = <Map<String, dynamic>>[];
  final rawSent = <String>[];
  void Function(Map<String, dynamic> cmd)? onSend;
  bool closed = false;

  @override
  Stream<String> get lines => _out.stream;

  @override
  void send(String line) {
    rawSent.add(line);
    final m = jsonDecode(line) as Map<String, dynamic>;
    sent.add(m);
    onSend?.call(m);
  }

  /// Pretend the hub wrote [m] to stdout.
  void emit(Map<String, dynamic> m) => _out.add(jsonEncode(m));

  void emitRaw(String line) => _out.add(line);

  /// Pretend the hub process exited.
  Future<void> die() => _out.close();

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// In-memory stand-in for the runner's `rapp/session` channel: records every call with its
/// channel arguments and lets a test play runner events.
class FakeSessionPort extends SessionPort {
  final calls = <(String, Map<String, Object?>)>[];
  final _events = StreamController<SessionEvent>.broadcast(sync: true);

  /// When set, `start` throws it.
  Object? startError;
  int doubleClickMs = 500;

  /// What `composer_paste` and `composer_attach` answer (a runner `PasteResult` map).
  Map<String, Object?>? pasteReply;

  /// What `fetch_clip` answers; null means `{copy: <next number>}`. [fetchError] is thrown instead.
  Map<String, Object?>? fetchReply;
  Object? fetchError;
  bool copyLocalReply = true;
  bool revealReply = true;
  int _nextCopy = 1;

  @override
  Stream<SessionEvent> get events => _events.stream;

  /// Pretend the runner sent [e].
  void emit(SessionEvent e) => _events.add(e);

  @override
  Future<Object?> invoke(String method, Map<String, Object?> args) async {
    calls.add((method, args));
    if (method == 'init') return {'doubleClickMs': doubleClickMs};
    if (method == 'start' && startError != null) throw startError!;
    if (method == 'composer_paste' || method == 'composer_attach') return pasteReply;
    if (method == 'fetch_clip') {
      if (fetchError != null) throw fetchError!;
      return fetchReply ?? {'copy': _nextCopy++};
    }
    if (method == 'copy_local') return copyLocalReply;
    if (method == 'reveal') return revealReply;
    return null;
  }
}
