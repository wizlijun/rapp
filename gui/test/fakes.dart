import 'dart:async';
import 'dart:convert';

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
