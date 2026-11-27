import 'dart:async';

import 'package:flutter/services.dart';
import 'package:rapp/embed/session_copy.dart';
import 'package:rapp/embed/session_host.dart';
import 'package:rapp/embed/session_link.dart';

/// A link whose packets the test pushes; counts acks and kills, keeps the lines sent.
class FakeLink implements SessionLink {
  final _packets = StreamController<Uint8List>();
  final _exit = Completer<int>();
  final _input = Completer<void>();
  final sent = <String>[];
  int acks = 0;
  int kills = 0;

  void push(List<int> packet) => _packets.add(Uint8List.fromList(packet));

  /// The input side breaks, as when the worker dies.
  void failInput() {
    if (!_input.isCompleted) _input.completeError(StateError('input closed'));
  }

  @override
  int get id => 7;
  @override
  Stream<Uint8List> get packets => _packets.stream;
  @override
  void send(String line) => sent.add(line);
  @override
  void ack() => acks++;
  @override
  Future<void> close() async {
    // The packet stream stays open, so a test can still push a frame after the port stopped.
    if (!_exit.isCompleted) _exit.complete(0);
  }
  @override
  void kill() {
    kills++;
    if (!_exit.isCompleted) _exit.complete(-9);
  }
  @override
  Future<int> get exitCode => _exit.future;
  @override
  Future<void> get inputDone => _input.future;
}

/// Opens [link] every time.
class OneLink implements SessionLinks {
  OneLink(this.link);
  final SessionLink link;
  @override
  Future<void> check() async {}
  @override
  Future<SessionLink> open() async => link;
}

/// [check] throws [error].
class FailingLinks implements SessionLinks {
  FailingLinks(this.error);
  final Object error;
  @override
  Future<void> check() async => throw error;
  @override
  Future<SessionLink> open() async => throw error;
}

/// No clipboard, no files, no detach, no trace.
class FakeHost implements SessionHost {
  /// How many times the port called [init].
  int inits = 0;
  @override
  Future<void> init(Future<Object?> Function(MethodCall call) onDetachCall) async {
    inits++;
  }
  @override
  String downloads() => '/nonexistent/downloads';
  @override
  Future<bool> reveal(String path) async => false;
  @override
  Future<SessionCopy?> readClipboard() async => null;
  @override
  Future<bool> writeClipboard(SessionCopy copy) async => false;
  @override
  Future<List<String>> chooseFiles() async => const [];
  @override
  String? get traceDir => null;
  @override
  MethodChannel? get detachChannel => null;
  @override
  bool get supportsInlineNativeComposer => true;
  @override
  bool get supportsDetach => false;
}

/// Opens [link]'s worth of nothing but notes when [check] runs.
class OrderLinks extends OneLink {
  OrderLinks(this.order) : super(FakeLink());
  final List<String> order;
  @override
  Future<void> check() async => order.add('check');
}

/// A [FakeHost] that notes when [init] runs.
class OrderHost extends FakeHost {
  OrderHost(this.order);
  final List<String> order;
  @override
  Future<void> init(Future<Object?> Function(MethodCall call) onDetachCall) async {
    order.add('host.init');
    await super.init(onDetachCall);
  }
}
