// Large composer text uses the same v6 side connection as the macOS sender.
// Socket backpressure keeps uploads separate from the picture and input pipes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class LinuxTextUpload {
  Socket? _socket;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _socket?.destroy();
  }

  Future<void> send(int port, String token, int item, Uint8List text) async {
    if (_cancelled) throw StateError('已取消');
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 8),
    );
    _socket = socket;
    if (_cancelled) {
      socket.destroy();
      throw StateError('已取消');
    }
    // Keep a handler installed even when the peer disconnects between writes.
    unawaited(socket.done.catchError((Object _) {}));
    final input = StreamIterator(socket.timeout(const Duration(seconds: 15)));
    List<int> chunk = const [];
    var offset = 0;
    Future<Uint8List> read(int n) async {
      final out = Uint8List(n);
      var at = 0;
      while (at < n) {
        if (offset == chunk.length) {
          if (!await input.moveNext()) throw const SocketException('上传连接断开');
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
      if ((h[0] == 24 && n == 8) || (h[0] == 25 && n == 0)) {
        return (h[0], await read(n));
      }
      if (h[0] == 3 && n >= 2 && n <= 65537) {
        final body = await read(n);
        final length = ByteData.sublistView(body).getUint16(0, Endian.little);
        if (length == n - 2) throw StateError(utf8.decode(body.sublist(2)));
      }
      throw const FormatException('无效的上传响应');
    }

    Future<void> packet(int kind, List<int> body) async {
      socket.add([kind, ..._u32(body.length)]);
      socket.add(body);
      await socket.flush().timeout(const Duration(seconds: 15));
    }

    try {
      await packet(23, [
        6,
        ..._string(token),
        ..._u32(item),
        0,
        ..._string('public.utf8-plain-text'),
        ..._string(''),
        ...(ByteData(
          8,
        )..setUint64(0, text.length, Endian.little)).buffer.asUint8List(),
      ]);
      final start = await message();
      if (start.$1 != 24) throw const FormatException('缺少上传起始响应');
      var sent = ByteData.sublistView(start.$2).getUint64(0, Endian.little);
      if (sent > text.length) throw const FormatException('无效的上传偏移');
      while (sent < text.length) {
        final end = (sent + 256 * 1024).clamp(0, text.length);
        await packet(25, Uint8List.sublistView(text, sent, end));
        sent = end;
      }
      final ack = await message();
      if (ack.$1 != 25) throw const FormatException('缺少上传完成确认');
    } finally {
      socket.destroy();
      await input.cancel();
      _socket = null;
    }
  }
}

Uint8List _u32(int n) =>
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List();
List<int> _string(String s) {
  final bytes = utf8.encode(s);
  if (bytes.length > 65535) throw const FormatException('字符串过长');
  return [
    ...(ByteData(
      2,
    )..setUint16(0, bytes.length, Endian.little)).buffer.asUint8List(),
    ...bytes,
  ];
}
