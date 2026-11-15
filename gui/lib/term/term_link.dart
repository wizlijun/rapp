// The socket to the local terminal worker: a token line, then one JSON object per line each way.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'term_wire.dart';

typedef Dial = Future<Socket> Function(String host, int port);

/// One wire line, newline included, is at most this long (`MAX_LINE` in the worker); longer ones are dropped.
const int maxLine = 65536;

class TermLink {
  TermLink._(this._socket) {
    _socket.listen(_onData, onError: (Object _) => _finish(), onDone: _finish, cancelOnError: true);
    // A write that fails because the peer is gone reports on this future, not at the call.
    unawaited(_socket.done.then<void>((_) {}, onError: (Object _) => _finish()));
  }

  /// Connects to 127.0.0.1:[port] and sends [token] as the first line.
  static Future<TermLink> connect(int port, String token, {Dial? dial}) async {
    final socket = await (dial ?? Socket.connect)('127.0.0.1', port);
    socket.write('$token\n');
    return TermLink._(socket);
  }

  final Socket _socket;
  final _messages = StreamController<TermOut>();
  final _done = Completer<void>();
  final _buf = BytesBuilder(copy: false);
  var _skipping = false;
  var _bytes = 0;

  /// Parsed lines; a line over [maxLine] bytes or one that does not parse is dropped.
  Stream<TermOut> get messages => _messages.stream;

  /// The connection ended, by either side or by an error.
  Future<void> get done => _done.future;

  void send(Map<String, Object?> m) => sendLine(jsonEncode(m));

  /// One line already encoded, without its newline.
  void sendLine(String line) {
    if (_done.isCompleted) return;
    try {
      _socket.write('$line\n');
    } catch (_) {
      _finish();
    }
  }

  /// Bytes received since the last call.
  int takeBytes() {
    final n = _bytes;
    _bytes = 0;
    return n;
  }

  void close() {
    _socket.destroy();
    _finish();
  }

  void _onData(Uint8List data) {
    _bytes += data.length;
    var start = 0;
    while (start < data.length) {
      final nl = data.indexOf(10, start);
      final end = nl < 0 ? data.length : nl;
      if (!_skipping) {
        if (_buf.length + (end - start) >= maxLine) {
          _buf.clear();
          _skipping = true;
        } else {
          _buf.add(Uint8List.sublistView(data, start, end));
        }
      }
      if (nl < 0) break;
      if (_skipping) {
        _skipping = false;
      } else {
        _line(_buf.takeBytes());
      }
      start = nl + 1;
    }
  }

  void _line(Uint8List bytes) {
    if (bytes.isEmpty) return;
    Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return;
    }
    final m = parseTermOut(json);
    if (m != null && !_messages.isClosed) _messages.add(m);
  }

  void _finish() {
    if (_done.isCompleted) return;
    _done.complete();
    _messages.close();
  }
}
