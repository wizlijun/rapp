// Linux uses the same Rust decoder as the standalone GTK client, in a headless
// child process. Binary pipes carry BGRA frames; no base64 or window reparenting.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'session_port.dart';
import 'linux_text_upload.dart';

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

class LinuxSessionPort extends SessionPort with WidgetsBindingObserver {
  LinuxSessionPort(this.executable, {Future<void> Function()? framePresented})
    : _framePresented =
          framePresented ?? (() => SchedulerBinding.instance.endOfFrame);
  final Future<void> Function() _framePresented;
  final String executable;
  final _events = StreamController<SessionEvent>.broadcast();
  final _sessions = <Object, _Session>{};
  final _starting = <Object>{};
  final _cancelledStarts = <Object>{};
  final _copies = <int, String>{};
  int _nextCopy = 1;
  Object? _focused;
  bool _disposed = false;

  @override
  bool get supportsDetach => false;
  @override
  Stream<SessionEvent> get events => _events.stream;

  @override
  Future<int> init() async {
    if (!await File(executable).exists()) {
      throw StateError('rapp-session not found: $executable');
    }
    WidgetsBinding.instance.addObserver(this);
    return 500;
  }

  void _emit(SessionEvent e) {
    if (!_disposed) _events.add(e);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _releaseFocus(clear: false);
  }

  void _releaseFocus({bool clear = true}) {
    final s = _sessions[_focused];
    if (s != null) {
      for (final code in s.held.toList()) {
        s.send({'cmd': 'key', 'keyCode': code, 'modifiers': 0, 'down': false});
      }
      s.held.clear();
    }
    if (clear) _focused = null;
  }

  @override
  bool handleKeyEvent(Object sid, KeyEvent event) {
    final s = _sessions[sid];
    if (_focused != sid ||
        s == null ||
        s.disconnected ||
        s.closed ||
        event.logicalKey == LogicalKeyboardKey.f11) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    // Super belongs to the Linux desktop. Ctrl maps to the remote Mac's Command.
    if (keyboard.isMetaPressed) return false;
    final code = linuxMacKeyCode(event.physicalKey);
    if (code == null) return false;
    final down = event is! KeyUpEvent;
    if (down) {
      s.held.add(code);
    } else {
      s.held.remove(code);
    }
    final mods =
        (keyboard.isShiftPressed ? 1 << 17 : 0) |
        (keyboard.isControlPressed ? 1 << 20 : 0) |
        (keyboard.isAltPressed ? 1 << 19 : 0);
    s.send({'cmd': 'key', 'keyCode': code, 'modifiers': mods, 'down': down});
    return true;
  }

  /// Holds [text] as a copy without a session.
  @visibleForTesting
  int seedCopyForTest(String text) {
    final copy = _nextCopy++;
    _copies[copy] = text;
    return copy;
  }

  @override
  Future<Object?> invoke(String method, Map<String, Object?> args) async {
    if (method == 'copy_local') {
      final text = _copies[args['copy']];
      if (text == null) return false;
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    }
    if (method == 'pin_save') {
      // Only text copies are kept on Linux.
      final text = _copies[args['copy']];
      final dir = args['text_dir'];
      final stem = args['stem'];
      if (text == null || dir is! String || stem is! String) return null;
      try {
        await Directory(dir).create(recursive: true);
        var file = File('$dir/$stem.md');
        for (var k = 2; await file.exists(); k++) {
          file = File('$dir/$stem-$k.md');
        }
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(text);
        await tmp.rename(file.path);
        return {'path': file.path};
      } on FileSystemException {
        return null;
      }
    }
    if (method == 'pin_load') {
      final path = args['path'];
      if (path is! String || !path.endsWith('.md')) return null;
      try {
        final copy = _nextCopy++;
        _copies[copy] = await File(path).readAsString();
        return {'copy': copy, 'kind': 'text'};
      } on FileSystemException {
        return null;
      }
    }
    if (method == 'drop_copy') {
      _copies.remove(args['copy']);
      return null;
    }
    if (method == 'reveal') {
      final path = args['path'];
      if (path is! String) return false;
      final file = File(path);
      if (!await file.exists()) return false;
      try {
        return (await Process.run('xdg-open', [
              file.absolute.parent.path,
            ])).exitCode ==
            0;
      } on ProcessException {
        return false;
      }
    }
    final sid = args['sid'];
    if (method == 'picture_focus') {
      if (_focused != sid) _releaseFocus();
      _focused = sid;
      return null;
    }
    if (method == 'start') {
      if (_disposed ||
          sid == null ||
          _sessions.containsKey(sid) ||
          _starting.contains(sid)) {
        throw StateError('Invalid session');
      }
      _starting.add(sid);
      late final Process process;
      try {
        process = await Process.start(executable, const []);
      } catch (_) {
        _cancelledStarts.remove(sid);
        rethrow;
      } finally {
        _starting.remove(sid);
      }
      final cancelled = _cancelledStarts.remove(sid);
      if (_disposed || cancelled) {
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        unawaited(process.stdin.close().catchError((Object _) {}));
        process.kill(ProcessSignal.sigkill);
        throw StateError('Session start cancelled');
      }
      final s = _Session(
        sid,
        process,
        _emit,
        _framePresented,
        args['port'] as int,
        args['token'] as String,
      );
      _sessions[sid] = s;
      unawaited(process.stderr.drain<void>());
      unawaited(
        process.stdin.done.catchError((Object _) {
          s.disconnect('session worker stopped');
        }),
      );
      s.send({'cmd': 'start', ...args, 'density': _density(args['density'])});
      unawaited(
        s.read().whenComplete(() {
          if (s.closed && identical(_sessions[sid], s)) _sessions.remove(sid);
          if (_focused == sid) _focused = null;
        }),
      );
      return null;
    }
    if (method == 'close' && _starting.contains(sid)) {
      _cancelledStarts.add(sid!);
    }
    final s = _sessions[sid];
    if (method == 'fetch_clip') {
      if (s == null || s.closed || s.disconnected) {
        return {'error': '远端已断开，复制不到'};
      }
      final text = s.clips[args['clip']];
      if (!s.clips.containsKey(args['clip'])) return {'error': 'unknown clip'};
      if (text == null) return {'error': '不是完整文字；Linux 暂不支持图片和文件传输'};
      final copy = _nextCopy++;
      _copies[copy] = text;
      return {'copy': copy};
    }
    if (s == null) return null;
    if (method != 'close' && s.disconnected) return null;
    switch (method) {
      case 'close':
        if (_focused == sid) _releaseFocus();
        s.close('closed');
        _sessions.remove(sid);
      case 'set_stream':
        s.send({'cmd': method, ...args, 'density': _density(args['density'])});
      case 'select_window':
        s.selected = args['window'] as int;
        s.send({'cmd': method, ...args});
      case 'mouse':
        if (args['kind'] == 'down') s.selected = args['window'] as int;
        s.send({'cmd': method, ...args});
      case 'scroll':
      case 'key':
      case 'resize':
      case 'menu_pick':
      case 'close_window':
      case 'select_input':
        s.send({'cmd': method, ...args});
      case 'move_top_left':
        final id = args['window'];
        var slot = 0.0;
        while (s.windows.any(
          (w) =>
              w.id != id &&
              w.decorated &&
              (w.rect.left - slot).abs() < 14 &&
              (w.rect.top.clamp(40, double.infinity) -
                          slot.clamp(40, double.infinity))
                      .abs() <
                  14,
        )) {
          slot += 28;
        }
        s.send({'cmd': 'move', 'window': id, 'x': slot, 'y': slot});
      case 'composer_paste':
        return {'text': (await Clipboard.getData(Clipboard.kTextPlain))?.text};
      case 'composer_attach':
        return {'status': 'Linux 暂不支持文件附件；可粘贴或输入文字'};
      case 'composer_send':
        unawaited(s.sendPieces(List<Object?>.from(args['pieces'] as List)));
      case 'clip_pick':
        final text = s.clips[args['clip']];
        if (text != null) {
          if (args['insert'] == true) {
            _emit(ComposerInsertEvent(s.sid, PasteResult(text: text)));
          } else {
            await Clipboard.setData(ClipboardData(text: text));
          }
        } else {
          s.showStatus(
            s.clips.containsKey(args['clip'])
                ? 'Linux 暂不支持取用图片、文件和截断文字'
                : '取用没成功：太旧了，远端已不保留',
          );
        }
    }
    return null;
  }

  double _density(Object? choice) => choice == 'original'
      ? 8
      : choice == 'saver1x'
      ? 1
      : (WidgetsBinding
                    .instance
                    .platformDispatcher
                    .views
                    .firstOrNull
                    ?.devicePixelRatio ??
                1)
            .clamp(0.1, 8)
            .toDouble();

  @override
  void dispose() {
    _releaseFocus();
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _sessions.values.toList()) {
      s.close('closed');
    }
    _sessions.clear();
    _copies.clear();
    unawaited(_events.close());
  }
}

void _retire(ui.Image? image) {
  if (image == null) return;
  SchedulerBinding.instance.addPostFrameCallback((_) => image.dispose());
  SchedulerBinding.instance.scheduleFrame();
}

class _Session {
  _Session(
    this.sid,
    this.process,
    this.emit,
    this.framePresented,
    this.port,
    this.token,
  );
  final int port;
  final String token;
  final Future<void> Function() framePresented;
  final _closed = Completer<void>();
  final Object sid;
  final Process process;
  final void Function(SessionEvent) emit;
  List<RemoteWindow> windows = [];
  final _pictures = <int, RemoteWindow>{};
  Uint8List? _pendingFrame;
  bool _rendering = false;
  Completer<void>? _renderWait;

  void queueFrame(Uint8List bytes) {
    // Latest-frame mailbox: decoding/display must never block control events.
    _pendingFrame = bytes;
    if (!_rendering) unawaited(drainFrames());
  }

  Future<void> drainFrames() async {
    _rendering = true;
    try {
      while (!closed && !disconnected && _pendingFrame != null) {
        final bytes = _pendingFrame!;
        _pendingFrame = null;
        await frame(bytes);
        if (!closed && !disconnected) {
          // Use a per-frame stop signal: registering on one long-lived future
          // would retain a callback for every displayed frame until disconnect.
          final stop = Completer<void>();
          _renderWait = stop;
          await Future.any([framePresented(), stop.future]);
          _renderWait = null;
        }
      }
    } catch (e) {
      disconnect('画面解码失败：$e');
    } finally {
      _renderWait = null;
      _rendering = false;
    }
  }

  final clips = <int, String?>{};
  final held = <int>{};
  int? selected;
  bool closed = false;
  bool disconnected = false;

  bool _sending = false;
  int _nextSeq = 1;
  final _pastes = <int, Completer<String>>{};
  LinuxTextUpload? _upload;
  Timer? _statusTimer;

  void showStatus(String message) {
    _statusTimer?.cancel();
    emit(TransferStatusEvent(sid, message));
    _statusTimer = Timer(const Duration(seconds: 5), () {
      if (!closed && !disconnected) emit(TransferStatusEvent(sid, null));
    });
  }

  Future<void> sendPieces(List<Object?> pieces) async {
    if (_sending || closed || disconnected) return;
    _sending = true;
    var sent = 0;
    String? failure;
    emit(ComposerStateEvent(sid, sending: true));
    try {
      for (final piece in pieces) {
        if (piece is! Map || piece['text'] is! String) {
          throw StateError('Linux 暂不支持文件和图片发送');
        }
        final text = piece['text'] as String;
        final bytes = utf8.encode(text);
        if (bytes.length > 1024 * 1024) throw StateError('文字超过 1 MB');
        if (closed || disconnected) throw StateError('远端已断开，未发送');
        // Never recycle sequence IDs: a late reply must not finish a later send.
        if (_nextSeq > 0xffffffff) throw StateError('请重新连接后发送');
        final seq = _nextSeq++;
        final source = <String, Object?>{'text': text};
        if (bytes.length >= 60000) {
          final upload = LinuxTextUpload();
          _upload = upload;
          try {
            await upload.send(port, token, seq, bytes);
          } finally {
            _upload = null;
          }
          source
            ..clear()
            ..['item'] = seq;
        }
        if (closed || disconnected) throw StateError('远端已断开，未发送');
        final reply = Completer<String>();
        _pastes[seq] = reply;
        try {
          if (selected != null) {
            send({'cmd': 'select_window', 'window': selected});
          }
          send({'cmd': 'paste', 'seq': seq, ...source});
          final error = await reply.future.timeout(
            const Duration(seconds: 15),
            onTimeout: () => '未收到远端的确认，请检查远端内容后再重试',
          );
          if (error.isNotEmpty) {
            failure = error;
            break;
          }
          sent++;
        } finally {
          _pastes.remove(seq);
        }
      }
    } catch (e) {
      failure = e is StateError ? e.message.toString() : '发送没成功：$e';
    } finally {
      _sending = false;
      if (!closed) {
        emit(
          ComposerStateEvent(
            sid,
            sending: false,
            done: ComposerDone(sent, failure),
          ),
        );
      }
    }
  }

  void send(Map<String, Object?> args) {
    if (!closed && !disconnected) process.stdin.writeln(jsonEncode(args));
  }

  void publish() {
    emit(
      WindowsEvent(sid, [
        for (final w in windows) _withPicture(w, _pictures[w.id]),
      ]),
    );
  }

  Future<void> read() async {
    try {
      await for (final packet in sessionPackets(process.stdout)) {
        if (closed || disconnected) break;
        if (packet[0] == 1) {
          queueFrame(Uint8List.sublistView(packet, 1));
        } else if (packet[0] == 0) {
          final m =
              jsonDecode(utf8.decode(packet.sublist(1)))
                  as Map<String, dynamic>;
          final method = m.remove('event') as String;
          if (method == 'disconnected' || method == 'closed') {
            disconnect(m['reason'] as String);
            break;
          }
          if (method == 'paste_result') {
            final reply = _pastes[m['seq']];
            if (reply != null && !reply.isCompleted) {
              reply.complete(m['error'] as String);
            }
          } else if (method == 'clip') {
            final text = m['truncated'] == false ? m['text'] as String? : null;
            clips.remove(m['id']);
            clips[m['id'] as int] = text;
            while (clips.length > 100) {
              clips.remove(clips.keys.first);
            }
            emit(
              ClipsEvent(
                sid,
                clips.entries
                    .toList()
                    .reversed
                    .map(
                      (c) => ClipRow(
                        c.key,
                        c.value == null
                            ? '图片、文件或过长文字（暂不支持）'
                            : c.value!
                                  .replaceAll('\n', ' ')
                                  .characters
                                  .take(80)
                                  .toString(),
                        c.value != null,
                      ),
                    )
                    .toList(),
              ),
            );
          } else {
            final e = parseSessionEvent(method, {...m, 'sid': sid});
            if (e is WindowsEvent) {
              windows = e.windows;
              for (final id in _pictures.keys.toList()) {
                if (!windows.any((w) => w.id == id)) {
                  _retire(_pictures.remove(id)?.image);
                }
              }
              if (!windows.any((w) => w.id == selected)) {
                selected = windows.where((w) => w.decorated).firstOrNull?.id;
              }
              publish();
            } else if (e != null) {
              emit(e);
            }
          }
        } else {
          throw const FormatException('Unknown worker packet');
        }
      }
      disconnect('remote session ended');
    } catch (e) {
      disconnect('连接失败：$e');
    }
  }

  Future<void> frame(Uint8List bytes) async {
    if (bytes.length < 24) throw const FormatException('Truncated frame');
    final b = ByteData.sublistView(bytes);
    final width = b.getUint32(0, Endian.little),
        height = b.getUint32(4, Endian.little);
    final r = ui.Rect.fromLTWH(
      b.getFloat32(8, Endian.little),
      b.getFloat32(12, Endian.little),
      b.getFloat32(16, Endian.little),
      b.getFloat32(20, Endian.little),
    );
    if (width == 0 ||
        height == 0 ||
        width * height > 8192 * 8192 ||
        bytes.length != 24 + width * height * 4 ||
        !r.isFinite ||
        r.isEmpty) {
      throw const FormatException('Invalid decoded frame');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(
      Uint8List.sublistView(bytes, 24),
    );
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.bgra8888,
    );
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await descriptor.instantiateCodec();
      image = (await codec.getNextFrame()).image;
      if (closed || disconnected) return;
      var geometryChanged = false;
      for (final w in windows) {
        final content = ui.Rect.fromLTRB(
          w.rect.left,
          w.rect.top + w.titleBar,
          w.rect.right,
          w.rect.bottom,
        );
        final crop = content.intersect(r);
        if (crop.isEmpty) {
          // Do not retain an entire old canvas for a window outside this frame.
          // Selecting it raises the remote window and supplies a fresh picture.
          final old = _pictures.remove(w.id);
          if (old != null) {
            _retire(old.image);
            geometryChanged = true;
          }
          continue;
        }
        final source = ui.Rect.fromLTWH(
          (crop.left - r.left) * width / r.width,
          (crop.top - r.top) * height / r.height,
          crop.width * width / r.width,
          crop.height * height / r.height,
        );
        final visible = ui.Rect.fromLTWH(
          (crop.left - content.left) / content.width,
          (crop.top - content.top) / content.height,
          crop.width / content.width,
          crop.height / content.height,
        );
        final old = _pictures[w.id];
        final frames = old?.frames ?? ValueNotifier<WindowFrame?>(null);
        _retire(frames.value?.image);
        frames.value = WindowFrame(image.clone(), source);
        if (old == null || old.visible != visible) geometryChanged = true;
        _pictures[w.id] = RemoteWindow(
          id: w.id,
          parent: w.parent,
          kind: w.kind,
          title: w.title,
          rect: w.rect,
          titleBar: w.titleBar,
          resizable: w.resizable,
          focused: w.focused,
          texture: null,
          visible: visible,
          frames: frames,
        );
      }
      if (geometryChanged) publish();
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  // A failed link retains its last images until explicit close (0.4.1 lifecycle).
  void disconnect(String reason) {
    if (closed || disconnected) return;
    disconnected = true;
    _stopTransport();
    emit(DisconnectedEvent(sid, reason));
  }

  void _stopTransport() {
    if (_closed.isCompleted) return;
    _statusTimer?.cancel();
    _upload?.cancel();
    for (final reply in _pastes.values) {
      if (!reply.isCompleted) reply.complete('远端已断开，发送未确认；请检查远端内容后再重试');
    }
    held.clear();
    _pendingFrame = null;
    _closed.complete();
    _renderWait?.complete();
    unawaited(process.stdin.close().catchError((Object _) {}));
    // EOF wakes the worker even if the host stopped producing frames.
    final timer = Timer(
      const Duration(seconds: 2),
      () => process.kill(ProcessSignal.sigkill),
    );
    unawaited(process.exitCode.then((_) => timer.cancel()));
  }

  void close(String reason) {
    if (closed) return;
    closed = true;
    _stopTransport();
    for (final p in _pictures.values) {
      _retire(p.image);
    }
    _pictures.clear();
    emit(ClosedEvent(sid, reason));
  }
}

RemoteWindow _withPicture(RemoteWindow w, RemoteWindow? p) => RemoteWindow(
  id: w.id,
  parent: w.parent,
  kind: w.kind,
  title: w.title,
  rect: w.rect,
  titleBar: w.titleBar,
  resizable: w.resizable,
  focused: w.focused,
  texture: null,
  visible: p?.visible ?? const ui.Rect.fromLTWH(0, 0, 1, 1),
  image: p?.image,
  source: p?.source,
  frames: p?.frames,
);

/// Physical USB HID positions -> Mac key codes, independent of the local layout.
int? linuxMacKeyCode(PhysicalKeyboardKey key) {
  const letters = [
    0,
    11,
    8,
    2,
    14,
    3,
    5,
    4,
    34,
    38,
    40,
    37,
    46,
    45,
    31,
    35,
    12,
    15,
    1,
    17,
    32,
    9,
    13,
    7,
    16,
    6,
  ];
  final usage = key.usbHidUsage;
  if (usage >= 0x70004 && usage <= 0x7001d) return letters[usage - 0x70004];
  const keys = <int, int>{
    0x1e: 18,
    0x1f: 19,
    0x20: 20,
    0x21: 21,
    0x22: 23,
    0x23: 22,
    0x24: 26,
    0x25: 28,
    0x26: 25,
    0x27: 29,
    0x28: 36,
    0x29: 53,
    0x2a: 51,
    0x2b: 48,
    0x2c: 49,
    0x2d: 27,
    0x2e: 24,
    0x2f: 33,
    0x30: 30,
    0x31: 42,
    0x33: 41,
    0x34: 39,
    0x35: 50,
    0x36: 43,
    0x37: 47,
    0x38: 44,
    0x3a: 122,
    0x3b: 120,
    0x3c: 99,
    0x3d: 118,
    0x3e: 96,
    0x3f: 97,
    0x40: 98,
    0x41: 100,
    0x42: 101,
    0x43: 109,
    0x44: 103,
    0x45: 111,
    0x4a: 115,
    0x4b: 116,
    0x4c: 117,
    0x4d: 119,
    0x4e: 121,
    0x4f: 124,
    0x50: 123,
    0x51: 125,
    0x52: 126,
    0x54: 75,
    0x55: 67,
    0x56: 78,
    0x57: 69,
    0x58: 76,
    0x59: 83,
    0x5a: 84,
    0x5b: 85,
    0x5c: 86,
    0x5d: 87,
    0x5e: 88,
    0x5f: 89,
    0x60: 91,
    0x61: 92,
    0x62: 82,
    0x63: 65,
    0xe0: 55,
    0xe1: 56,
    0xe2: 58,
    0xe4: 54,
    0xe5: 60,
    0xe6: 61,
  };
  return usage >> 16 == 7 ? keys[usage & 0xffff] : null;
}
