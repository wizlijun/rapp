// Protocol v5/v6 side connections. One queue per session, bounded chunks, disk
// streaming and resumable uploads/downloads. Never runs on the picture pipe.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const linuxMemoryLimit = 256 * 1024 * 1024;
const linuxChunkSize = 256 * 1024;

String safeTransferName(String name) {
  final last = name.replaceAll('\\', '/').split('/').last;
  final clean = last
      .replaceAll(RegExp(r'[:\x00-\x1f\x7f]'), '')
      .replaceFirst(RegExp(r'^\.+'), '');
  return clean.isEmpty ? 'file' : clean;
}

Future<String> unusedTransferPath(String dir, String name) async {
  final safe = safeTransferName(name);
  final dot = safe.lastIndexOf('.');
  final base = dot > 0 ? safe.substring(0, dot) : safe;
  final ext = dot > 0 ? safe.substring(dot) : '';
  for (var n = 1; ; n++) {
    final path = '$dir/${n == 1 ? safe : '$base ($n)$ext'}';
    if (!await File(path).exists() &&
        !await Directory(path).exists() &&
        !await File('$path.rapp-part').exists()) {
      return path;
    }
  }
}

class LinuxTransferProgress {
  const LinuxTransferProgress(
    this.id,
    this.down,
    this.name,
    this.kind,
    this.done,
    this.total,
    this.state, {
    this.path,
    this.error,
  });
  final int id, done, total;
  final bool down;
  final String name, kind, state;
  final String? path, error;
}

class _Job {
  _Job(this.id, this.down, this.name, this.kind, this.total);
  final int id;
  final bool down;
  final String name, kind;
  int total, done = 0;
  bool cancelled = false;
  Socket? socket;
  void cancel() {
    cancelled = true;
    socket?.destroy();
  }

  void check() {
    if (cancelled) throw StateError('已取消');
  }
}

class LinuxTransfers {
  LinuxTransfers(
    this.port,
    this.token, {
    required this.downloads,
    required this.progress,
    this.retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
  });
  final int port;
  final String token;
  final String Function() downloads;
  final void Function(LinuxTransferProgress) progress;
  final List<Duration> retryDelays;
  final _jobs = <int, _Job>{};
  final _names = <String, String>{};
  Future<void> _tail = Future.value();
  int _next = 1;
  bool _closed = false;

  void cancel([int? id]) {
    for (final j in _jobs.values) {
      if (id == null || j.id == id) j.cancel();
    }
  }

  void close() {
    _closed = true;
    cancel();
  }

  Future<T> _enqueue<T>(
    bool down,
    String name,
    String kind,
    int total,
    Future<T> Function(_Job) work,
  ) {
    final job = _Job(_next++, down, name, kind, total);
    _jobs[job.id] = job;
    _report(job, 'running');
    final result = _tail.then((_) async {
      try {
        if (_closed) job.cancel();
        job.check();
        final value = await work(job);
        job.check();
        job.done = job.total;
        _report(job, 'done', path: value is String && down ? value : null);
        return value;
      } catch (e) {
        _report(
          job,
          job.cancelled ? 'cancelled' : 'failed',
          error: job.cancelled ? null : '$e',
        );
        rethrow;
      } finally {
        _jobs.remove(job.id);
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _report(_Job j, String state, {String? path, String? error}) => progress(
    LinuxTransferProgress(
      j.id,
      j.down,
      j.name,
      j.kind,
      j.done,
      j.total,
      state,
      path: path,
      error: error,
    ),
  );

  Future<T> _retry<T>(_Job j, Future<T> Function(_Wire) work) async {
    for (var attempt = 0; ; attempt++) {
      j.check();
      _Wire? wire;
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(seconds: 8),
        );
        j.socket = socket;
        wire = _Wire(socket);
        j.check();
        return await work(wire);
      } on SocketException {
        j.check();
        if (attempt >= retryDelays.length) rethrow;
      } on TimeoutException {
        j.check();
        if (attempt >= retryDelays.length) rethrow;
      } finally {
        await wire?.close();
        j.socket = null;
      }
      await Future<void>.delayed(retryDelays[attempt]);
    }
  }

  Future<void> upload({
    required int item,
    required String kind,
    required String uti,
    String name = '',
    Uint8List? bytes,
    String? file,
  }) async {
    final total = file == null ? bytes!.length : await File(file).length();
    if (kind != 'files' && total > linuxMemoryLimit) {
      throw StateError('这一项超过 256 MB');
    }
    final code = ['text', 'image', 'files', 'data'].indexOf(kind);
    if (code < 0) throw StateError('不支持这一项');
    return _enqueue(false, name, kind, total, (j) async {
      final handle = file == null ? null : await File(file).open();
      try {
        await _retry(j, (w) async {
          await w.send(23, [
            6,
            ...wireString(token),
            ...wireInt(item, 4),
            code,
            ...wireString(uti),
            ...wireString(name),
            ...wireInt(total, 8),
          ]);
          final first = await w.message();
          if (first.$1 != 24 || first.$2.length != 8) {
            throw const FormatException('缺少上传起始响应');
          }
          j.done = ByteData.sublistView(first.$2).getUint64(0, Endian.little);
          if (j.done > total) throw const FormatException('无效的上传偏移');
          _report(j, 'running');
          if (handle != null) await handle.setPosition(j.done);
          while (j.done < total) {
            j.check();
            final n = (total - j.done).clamp(0, linuxChunkSize);
            final chunk = handle == null
                ? Uint8List.sublistView(bytes!, j.done, j.done + n)
                : await handle.read(n);
            if (chunk.isEmpty) throw StateError('文件已改变，无法继续上传');
            await w.send(25, chunk);
            j.done += chunk.length;
            _report(j, 'running');
          }
          final ack = await w.message();
          if (ack.$1 != 25 || ack.$2.isNotEmpty) {
            throw const FormatException('缺少上传完成确认');
          }
        });
      } finally {
        await handle?.close();
      }
    });
  }

  Future<Object> download({
    required int clip,
    required int index,
    required String name,
    required int total,
    required bool toDisk,
  }) => _enqueue(true, name, toDisk ? 'files' : 'data', total, (j) async {
    if (!toDisk && total > linuxMemoryLimit) throw StateError('这一项超过 256 MB');
    RandomAccessFile? handle;
    String? path;
    final memory = BytesBuilder(copy: false);
    try {
      if (toDisk) {
        final dir = downloads();
        await Directory(dir).create(recursive: true);
        final key = '$dir/$clip/$index';
        path = _names[key] ??= await unusedTransferPath(dir, name);
        final part = File('$path.rapp-part');
        handle = await part.open(mode: FileMode.append);
        j.done = await handle.length();
        if (j.done > total) {
          await handle.truncate(0);
          j.done = 0;
        }
        await handle.setPosition(j.done);
      }
      var changed = false;
      await _retry(j, (w) async {
        await w.send(22, [
          6,
          ...wireString(token),
          ...wireInt(clip, 4),
          ...wireInt(index, 2),
          ...wireInt(j.done, 8),
        ]);
        final first = await w.message();
        if (first.$1 != 24 || first.$2.length != 8) {
          throw const FormatException('缺少下载起始响应');
        }
        final size = ByteData.sublistView(first.$2).getUint64(0, Endian.little);
        if (size != j.total) {
          if (changed) throw StateError('远端文件一直在改变');
          if (!toDisk && size > linuxMemoryLimit) {
            throw StateError('这一项超过 256 MB');
          }
          changed = true;
          j.total = size;
          j.done = 0;
          memory.clear();
          await handle?.truncate(0);
          await handle?.setPosition(0);
          throw const SocketException('远端文件已改变，重新下载');
        }
        _report(j, 'running');
        while (j.done < j.total) {
          j.check();
          final chunk = await w.message();
          if (chunk.$1 != 25 ||
              chunk.$2.isEmpty ||
              chunk.$2.length > j.total - j.done) {
            throw const FormatException('无效的下载数据');
          }
          if (handle == null) {
            memory.add(chunk.$2);
          } else {
            await handle.writeFrom(chunk.$2);
          }
          j.done += chunk.$2.length;
          _report(j, 'running');
        }
      });
      if (handle == null) return memory.takeBytes();
      await handle.close();
      handle = null;
      // A different app may have created the final name during the transfer.
      if (await File(path!).exists() || await Directory(path).exists()) {
        final fresh = await unusedTransferPath(File(path).parent.path, name);
        await File('$path.rapp-part').rename(fresh);
        return fresh;
      }
      await File('$path.rapp-part').rename(path);
      return path;
    } finally {
      await handle?.close();
    }
  });
}

Uint8List wireInt(int n, int size) {
  final b = ByteData(size);
  switch (size) {
    case 2:
      b.setUint16(0, n, Endian.little);
    case 4:
      b.setUint32(0, n, Endian.little);
    case 8:
      b.setUint64(0, n, Endian.little);
  }
  return b.buffer.asUint8List();
}

List<int> wireString(String s) {
  final b = utf8.encode(s);
  if (b.length > 65535) throw const FormatException('字符串过长');
  return [...wireInt(b.length, 2), ...b];
}

class _Wire {
  _Wire(this.socket)
    : input = StreamIterator(socket.timeout(const Duration(seconds: 15))) {
    unawaited(socket.done.catchError((Object _) {}));
  }
  final Socket socket;
  final StreamIterator<Uint8List> input;
  Uint8List chunk = Uint8List(0);
  int offset = 0;
  Future<Uint8List> read(int n) async {
    final out = Uint8List(n);
    var at = 0;
    while (at < n) {
      if (offset == chunk.length) {
        if (!await input.moveNext()) throw const SocketException('传输连接断开');
        chunk = input.current;
        offset = 0;
      }
      final count = (n - at).clamp(0, chunk.length - offset);
      out.setRange(at, at + count, chunk, offset);
      at += count;
      offset += count;
    }
    return out;
  }

  Future<(int, Uint8List)> message() async {
    final h = await read(5);
    final n = ByteData.sublistView(h).getUint32(1, Endian.little);
    if (!((h[0] == 24 && n == 8) ||
        (h[0] == 25 && n <= linuxChunkSize) ||
        (h[0] == 3 && n >= 2 && n <= 65537))) {
      throw const FormatException('无效的传输响应');
    }
    final body = await read(n);
    if (h[0] == 3) {
      if (ByteData.sublistView(body).getUint16(0, Endian.little) != n - 2) {
        throw const FormatException('无效的错误响应');
      }
      throw StateError(utf8.decode(body.sublist(2)));
    }
    return (h[0], body);
  }

  Future<void> send(int type, List<int> bytes) async {
    socket.add([type, ...wireInt(bytes.length, 4)]);
    socket.add(bytes);
    await socket.flush().timeout(const Duration(seconds: 15));
  }

  Future<void> close() async {
    socket.destroy();
    await input.cancel();
  }
}
