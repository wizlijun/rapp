import 'dart:io';
import 'dart:typed_data';

import 'session_worker.dart';

/// 一条会话通路：一个 rapp-session 子进程（Linux、Windows），或进程内的会话库（安卓，P1b）。
///
/// Contract:
/// - [id], [packets], [exitCode] and [inputDone] are usable right after [SessionLinks.open]
///   returns, before the port's first [send].
/// - The port's first [send] is always the `{"cmd":"start",...}` line.
/// - Every frame packet (kind 1) taken from [packets] is acked exactly once by the port, also
///   after [close]. So [ack] may be called after [close] and must then be harmless, and
///   [close] must not wait for outstanding acks.
abstract class SessionLink {
  /// 追踪日志里的编号（子进程是 pid）。
  int get id;

  /// 管道格式的包：首字节 0 是事件 JSON，1 是「24 字节帧头 + BGRA」。
  Stream<Uint8List> get packets;

  /// 一行 JSON 命令，不带换行。The first call is always the `start` command.
  void send(String line);

  /// 一帧用完了（做成图片或决定丢掉）；子进程那边是空操作。Called once per frame packet, even
  /// after [close]; must be harmless then.
  void ack();

  /// 不再发命令（关输入）。Must not depend on outstanding acks; later [ack]s stay harmless.
  Future<void> close();

  /// 立刻结束。
  void kill();

  Future<int> get exitCode;

  /// 输入那头断了时带错误完成。
  Future<void> get inputDone;
}

abstract class SessionLinks {
  /// 端口 init 时调；不可用就抛。
  Future<void> check();

  /// Returns a link whose [SessionLink.id], [SessionLink.packets], [SessionLink.exitCode] and
  /// [SessionLink.inputDone] already work, before the port's first [SessionLink.send] (the
  /// `start` command).
  Future<SessionLink> open();
}

class ProcessSessionLink implements SessionLink {
  ProcessSessionLink(this._worker);

  final SessionWorker _worker;

  @override
  int get id => _worker.pid;

  @override
  Stream<Uint8List> get packets => _worker.packets;

  @override
  void send(String line) => _worker.send(line);

  // The pipe has its own back-pressure.
  @override
  void ack() {}

  @override
  Future<void> close() => _worker.closeInput();

  @override
  void kill() => _worker.kill(ProcessSignal.sigkill);

  @override
  Future<int> get exitCode => _worker.exitCode;

  @override
  Future<void> get inputDone => _worker.inputDone;
}

class ProcessSessionLinks implements SessionLinks {
  ProcessSessionLinks(this.executable);

  final String executable;

  @override
  Future<void> check() async {
    if (!File(executable).existsSync()) {
      throw StateError('rapp-session not found: $executable');
    }
  }

  @override
  Future<SessionLink> open() async => ProcessSessionLink(await SessionWorker.start(executable));
}
