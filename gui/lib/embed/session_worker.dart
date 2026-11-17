// Read the worker pipe outside Flutter's platform/UI event loop.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

class SessionWorker {
  SessionWorker._(
    this.pid,
    this.packets,
    this.send,
    this.closeInput,
    this._kill,
    this.exitCode,
    this.inputDone,
  );

  final int pid;
  final Stream<Uint8List> packets;
  final void Function(String) send;
  final Future<void> Function() closeInput;
  final void Function(ProcessSignal) _kill;
  final Future<int> exitCode;
  final Future<void> inputDone;

  void kill([ProcessSignal signal = ProcessSignal.sigterm]) => _kill(signal);

  // Also used by tests that already own a subprocess.
  factory SessionWorker.fromProcess(Process process) {
    unawaited(process.stderr.drain<void>());
    return SessionWorker._(
      process.pid,
      sessionPackets(process.stdout),
      process.stdin.writeln,
      () async {
        await process.stdin.close();
      },
      (signal) {
        process.kill(signal);
      },
      process.exitCode,
      process.stdin.done.then<void>((_) {}),
    );
  }

  static Future<SessionWorker> start(String executable) async {
    final receive = ReceivePort();
    final started = Completer<int>();
    final exited = Completer<int>();
    final input = Completer<void>();
    // The isolate sends at most one packet before waiting for credit. Thus a
    // paused UI cannot build an unbounded queue of transferable 4K allocations.
    final packets = StreamController<TransferableTypedData>();
    SendPort? commands;
    var finished = false;
    var inputClosing = false;
    void finish(int code) {
      if (finished) return;
      finished = true;
      if (!started.isCompleted) {
        started.completeError(StateError('session worker did not start'));
      }
      if (!exited.isCompleted) exited.complete(code);
      if (!input.isCompleted) input.complete();
      unawaited(packets.close());
      receive.close();
    }

    receive.listen((message) {
      if (message == null) {
        finish(-1);
      } else if (message is List && message[0] == 'started') {
        commands = message[1] as SendPort;
        started.complete(message[2] as int);
      } else if (message is List && message[0] == 'packet') {
        packets.add(message[1] as TransferableTypedData);
      } else if (message is List && message[0] == 'input-closed') {
        if (!input.isCompleted) input.complete();
      } else if (message is List && message[0] == 'child-exited') {
        // Process lifetime is independent of a paused packet consumer. Keep
        // buffered output available until the consumer drains or cancels it.
        if (!exited.isCompleted) exited.complete(message[1] as int);
      } else if (message is List && message[0] == 'exited') {
        finish(message[1] as int);
      } else {
        final error = StateError(
          message is List ? '${message.last}' : '$message',
        );
        if (!started.isCompleted) {
          started.completeError(error);
        } else {
          packets.addError(error);
        }
        commands?.send(['kill', ProcessSignal.sigkill.signalNumber]);
        finish(-1);
      }
    });
    try {
      await Isolate.spawn(
        _readWorker,
        (executable, receive.sendPort),
        onError: receive.sendPort,
        onExit: receive.sendPort,
        debugName: 'rapp-pipe',
      );
      final pid = await started.future;
      Stream<Uint8List> transfer() async* {
        try {
          await for (final packet in packets.stream) {
            yield packet.materialize().asUint8List();
            commands!.send(['credit']);
          }
        } finally {
          commands!.send(['kill', ProcessSignal.sigkill.signalNumber]);
        }
      }

      return SessionWorker._(
        pid,
        transfer(),
        (line) {
          if (!finished && !inputClosing) commands!.send(['input', line]);
        },
        () {
          if (!finished && !inputClosing) commands!.send(['close']);
          inputClosing = true;
          return input.future;
        },
        (signal) {
          commands!.send(['kill', signal.signalNumber]);
        },
        exited.future,
        input.future,
      );
    } catch (_) {
      receive.close();
      unawaited(packets.close());
      rethrow;
    }
  }
}

Future<void> _readWorker((String, SendPort) args) async {
  final (executable, parent) = args;
  final commands = ReceivePort();
  Process? process;
  Completer<void>? credit;
  var stopping = false;
  try {
    final child = await Process.start(executable, const []);
    process = child;
    unawaited(
      child.exitCode.then((code) => parent.send(['child-exited', code])),
    );
    unawaited(child.stderr.drain<void>());
    unawaited(
      child.stdin.done.then(
        (_) {
          parent.send(['input-closed']);
        },
        onError: (Object error) {
          parent.send(['error', error.toString()]);
          child.kill(ProcessSignal.sigkill);
          if (credit?.isCompleted == false) credit!.complete();
          stopping = true;
        },
      ),
    );
    commands.listen((message) {
      switch (message[0]) {
        case 'credit':
          if (credit?.isCompleted == false) credit!.complete();
        case 'input':
          child.stdin.writeln(message[1] as String);
        case 'close':
          unawaited(child.stdin.close().catchError((Object _) {}));
        case 'kill':
          stopping = true;
          child.kill(
            message[1] == ProcessSignal.sigkill.signalNumber
                ? ProcessSignal.sigkill
                : ProcessSignal.sigterm,
          );
          if (credit?.isCompleted == false) credit!.complete();
      }
    });
    parent.send(['started', commands.sendPort, child.pid]);
    await for (final packet in sessionPackets(child.stdout)) {
      if (stopping) break;
      credit = Completer<void>();
      parent.send([
        'packet',
        TransferableTypedData.fromList([packet]),
      ]);
      await credit.future;
    }
    parent.send(['exited', await child.exitCode]);
  } catch (error) {
    parent.send(['error', error.toString()]);
  } finally {
    process?.kill(ProcessSignal.sigkill);
    commands.close();
  }
}

/// A bounded, streaming packet reader. Pausing here backpressures the worker's
/// stdout instead of accumulating decoded frames in Dart. The worker keeps
/// decoding the remote stream and replaces its pending complete canvas.
Stream<Uint8List> sessionPackets(Stream<List<int>> stream) async* {
  final iterator = StreamIterator(stream);
  List<int> chunk = const [];
  var offset = 0;
  Future<Uint8List?> read(int n, {bool eof = false}) async {
    final result = Uint8List(n);
    var written = 0;
    while (written < n) {
      if (offset == chunk.length) {
        if (!await iterator.moveNext()) {
          if (eof && written == 0) return null;
          throw const FormatException('Truncated session packet');
        }
        chunk = iterator.current;
        offset = 0;
        if (chunk.isEmpty) continue;
      }
      final take = (chunk.length - offset).clamp(0, n - written);
      result.setRange(written, written + take, chunk, offset);
      written += take;
      offset += take;
    }
    return result;
  }

  try {
    while (true) {
      final header = await read(4, eof: true);
      if (header == null) break;
      final n = ByteData.sublistView(header).getUint32(0, Endian.little);
      if (n < 1 || n > 8192 * 8192 * 4 + 25) {
        throw const FormatException('Invalid session packet size');
      }
      yield (await read(n))!;
    }
  } finally {
    await iterator.cancel();
  }
}
