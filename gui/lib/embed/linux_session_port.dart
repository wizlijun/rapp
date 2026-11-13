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
import 'linux_transfer.dart';
import 'linux_clipboard.dart';
import '../paths.dart';

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
  LinuxSessionPort(
    this.executable, {
    Future<void> Function()? framePresented,
    LinuxDesktop? desktop,
    String Function()? downloads,
  }) : desktop = desktop ?? LinuxDesktop(),
       downloads =
           downloads ??
           (() =>
               Platform.environment['RAPP_DOWNLOADS'] ??
               '${dataRoot(Platform.environment, Platform.operatingSystem)}/files/transfers'),
       _framePresented =
           framePresented ?? (() => SchedulerBinding.instance.endOfFrame);
  final Future<void> Function() _framePresented;
  final String executable;
  final LinuxDesktop desktop;
  final String Function() downloads;
  final _events = StreamController<SessionEvent>.broadcast();
  final _sessions = <Object, _Session>{};
  final _starting = <Object>{};
  final _cancelledStarts = <Object>{};
  final _copies = <int, LinuxCopy>{};
  int _nextCopy = 1;
  Object? _focused;
  bool _disposed = false;

  bool _native = false;
  Object? _dropSid;
  @override
  bool get supportsDetach => _native;
  @override
  Stream<SessionEvent> get events => _events.stream;

  @override
  Future<int> init() async {
    if (!await File(executable).exists()) {
      throw StateError('rapp-session not found: $executable');
    }
    try {
      _native = await desktop.channel.invokeMethod<bool>('init') ?? false;
      desktop.channel.setMethodCallHandler(_nativeEvent);
    } on MissingPluginException {
      _native = false;
    }
    WidgetsBinding.instance.addObserver(this);
    return 500;
  }

  void _emit(SessionEvent e) {
    if (_disposed) return;
    final s = _sessions[e.sid];
    if (_native && s?.detached == true) {
      if (e is ComposerInsertEvent) {
        _nativeCall('composer_insert', {
          'sid': e.sid,
          'text': e.insert.text,
          'blocks': [
            for (final b in e.insert.blocks) {'n': b.n, 'label': b.label},
          ],
        });
      }
      if (e is ComposerStateEvent && e.done != null) {
        _nativeCall('composer_done', {
          'sid': e.sid,
          'sent': e.done!.sent,
          'failure': e.done!.failure,
        });
      }
      if (e is ClipsEvent) s!.nativeClips();
      if (e is TransferStatusEvent) {
        _nativeCall('status', {'sid': e.sid, 'text': e.status ?? ''});
      }
      if (e is DisconnectedEvent) {
        _nativeCall('status', {
          'sid': e.sid,
          'text': '已断开：${e.reason}',
          'disconnected': true,
        });
      }
    }
    _events.add(e);
  }

  void _nativeCall(String method, Map<String, Object?> args) {
    unawaited(
      desktop.channel
          .invokeMethod<void>(method, args)
          .catchError((Object _) {}),
    );
  }

  Future<Object?> _nativeEvent(MethodCall call) async {
    final args = Map<String, Object?>.from(call.arguments as Map? ?? {});
    final sid = args['sid'] ?? _dropSid;
    final s = _sessions[sid];
    if (s == null || s.closed) return null;
    args['sid'] = sid;
    if (call.method == 'set_stream') {
      _emit(
        StreamChoiceEvent(
          s.sid,
          args['mode'] as String,
          args['density'] as String,
          args['fps'] as int,
        ),
      );
      await invoke(call.method, args);
    } else if (call.method == 'draft') {
      _emit(ComposerDraftEvent(s.sid, text: args['text'] as String?));
    } else if (call.method == 'composer_send') {
      _emit(
        ComposerDraftEvent(s.sid, text: args['text'] as String?, send: true),
      );
      await invoke(call.method, args);
    } else if (call.method == 'composer_drop_block') {
      _emit(ComposerDraftEvent(s.sid, drop: args['block'] as int?));
      await invoke(call.method, args);
    } else if (call.method == 'drop_files' ||
        call.method == 'composer_paste' ||
        call.method == 'composer_attach') {
      final result = call.method == 'drop_files'
          ? await s.insert(
              LinuxCopy(
                'files',
                files: List<String>.from(args['files'] as List),
              ),
            )
          : await invoke(call.method, args) as Map<String, Object?>?;
      if (result != null) {
        _emit(
          ComposerInsertEvent(
            s.sid,
            PasteResult(
              text: result['text'] as String?,
              blocks: [
                for (final b in result['blocks'] as List? ?? [])
                  BlockChip(b['n'] as int, b['label'] as String),
              ],
              status: result['status'] as String?,
            ),
          ),
        );
      }
    } else {
      await invoke(call.method, args);
    }
    return null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _releaseFocus(clear: false);
  }

  @override
  void dropTarget(Object? sid) {
    _dropSid = sid;
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
    _copies[copy] = LinuxCopy(
      'text',
      text: text,
      uti: 'public.utf8-plain-text',
    );
    return copy;
  }

  @override
  Future<Object?> invoke(String method, Map<String, Object?> args) async {
    if (method == 'copy_local') {
      final copy = _copies[args['copy']];
      return copy != null && await desktop.writeClipboard(copy);
    }
    if (method == 'pin_save') {
      final copy = _copies[args['copy']];
      if (copy == null) return null;
      try {
        return {
          'path': await saveLinuxCopy(
            copy,
            args['text_dir'] as String,
            args['file_dir'] as String,
            args['stem'] as String,
          ),
        };
      } catch (_) {
        return null;
      }
    }
    if (method == 'pin_load') {
      try {
        final value = await loadLinuxCopy(args['path'] as String);
        if (value == null) return null;
        final copy = _nextCopy++;
        _copies[copy] = value;
        return {'copy': copy, 'kind': value.kind};
      } catch (_) {
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
      if (sid != null) _dropSid = sid;
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
        downloads,
        desktop,
      );
      s.stream = {
        'mode': args['mode'],
        'fps': args['fps'],
        'density': args['density'],
      };
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
        return {'error': 'A 已断开，复制不到'};
      }
      try {
        final value = await s.fetch(args['clip'] as int);
        if (_disposed) return {'error': '会话已结束'};
        final copy = _nextCopy++;
        _copies[copy] = value;
        return {'copy': copy};
      } catch (e) {
        return {'error': e is StateError ? e.message : '$e'};
      }
    }
    if (s == null) return null;
    if (!['close', 'attach', 'raise_detached'].contains(method) &&
        s.disconnected) {
      return null;
    }
    switch (method) {
      case 'detach':
        if (!_native || s.detached) return null;
        await desktop.channel.invokeMethod<void>('detach', {
          'sid': sid,
          'text': args['text'],
          'blocks': args['blocks'],
        });
        s.detached = true;
        await s.nativeWindows();
        s.nativeClips();
        _nativeCall('stream', {'sid': sid, ...s.stream});
        await s.nativeFrame();
        _emit(DetachedEvent(s.sid, true));
      case 'attach':
        if (!s.detached) return null;
        await desktop.channel.invokeMethod<void>('attach', {'sid': sid});
        s.detached = false;
        _emit(DetachedEvent(s.sid, false, current: s.selected));
      case 'raise_detached':
        if (s.detached) _nativeCall('raise', {'sid': sid});
      case 'close':
        if (_focused == sid) _releaseFocus();
        s.close('closed');
        _sessions.remove(sid);
      case 'set_stream':
        s.stream = {
          'mode': args['mode'],
          'fps': args['fps'],
          'density': args['density'],
        };
        if (s.detached) _nativeCall('stream', {'sid': sid, ...s.stream});
        s.send({'cmd': method, ...args, 'density': _density(args['density'])});
      case 'select_window':
        s.selected = args['window'] as int;
        _dropSid = sid;
        s.send({'cmd': method, ...args});
      case 'mouse':
        if (args['kind'] == 'down') s.selected = args['window'] as int;
        s.send({'cmd': method, ...args});
      case 'scroll':
      case 'key':
      case 'resize':
      case 'menu_pick':
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
        try {
          return await s.insert(await desktop.readClipboard());
        } catch (e) {
          return {'status': '粘贴没成功：$e'};
        }
      case 'composer_attach':
        try {
          return await s.insert(
            LinuxCopy('files', files: await desktop.chooseFiles()),
          );
        } catch (e) {
          return {'status': '添加没成功：$e'};
        }
      case 'composer_drop_block':
        s.blocks.remove(args['block']);
      case 'cancel_transfer':
        s.transfers.cancel(args['id'] as int?);
      case 'composer_send':
        unawaited(s.sendPieces(List<Object?>.from(args['pieces'] as List)));
      case 'clip_pick':
        try {
          final copy = await s.fetch(args['clip'] as int);
          if (s.closed) return null;
          if (args['insert'] == true) {
            final result = await s.insert(copy);
            _emit(
              ComposerInsertEvent(
                s.sid,
                PasteResult(
                  text: result['text'] as String?,
                  blocks: [
                    for (final b in (result['blocks'] as List? ?? []))
                      BlockChip(b['n'] as int, b['label'] as String),
                  ],
                  status: result['status'] as String?,
                ),
              ),
            );
          } else {
            await desktop.writeClipboard(copy);
          }
        } catch (e) {
          s.showStatus(
            '取用没成功：${e is StateError && e.message == 'unknown clip'
                ? '太旧了，A 已不保留'
                : e is StateError
                ? e.message
                : e}',
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
    String Function() downloads,
    this.desktop,
  ) {
    transfers = LinuxTransfers(
      port,
      token,
      downloads: downloads,
      progress: (p) {
        emit(
          TransferProgressEvent(
            sid,
            p.id,
            p.down,
            p.name,
            p.done,
            p.total,
            TransferState.values.byName(p.state),
            p.path,
            p.error,
            kind: ClipKind.values.byName(p.kind),
          ),
        );
        if (p.state == 'running') {
          emit(
            TransferStatusEvent(
              sid,
              '${p.down ? '下载' : '上传'} ${p.name} ${p.total == 0 ? 100 : p.done * 100 ~/ p.total}%',
            ),
          );
        } else if (p.state == 'failed') {
          showStatus('传输没成功：${p.error}');
        } else {
          emit(TransferStatusEvent(sid, null));
        }
      },
    );
  }
  late final LinuxTransfers transfers;
  final LinuxDesktop desktop;
  bool detached = false;
  Map<String, Object?> stream = {
    'mode': 'color16',
    'density': 'adaptive',
    'fps': 15,
  };
  void nativeClips() {
    if (detached) {
      unawaited(
        desktop.channel
            .invokeMethod<void>('clips', {
              'sid': sid,
              'clips': [
                for (final c in clips.entries.toList().reversed)
                  {
                    'id': c.key,
                    'title': clipTitle(c.value),
                    'pickable': c.value['kind'] != 'unsupported',
                  },
              ],
            })
            .catchError((Object _) {}),
      );
    }
  }

  Uint8List? lastNativeFrame;
  List<dynamic> nativeWindowTable = [];
  List<dynamic> nativeMenuTable = [];
  Future<void> nativeWindows() async {
    if (detached) {
      await desktop.channel.invokeMethod<void>('windows', {
        'sid': sid,
        'windows': nativeWindowTable,
      });
      await desktop.channel.invokeMethod<void>('menus', {
        'sid': sid,
        'items': nativeMenuTable,
      });
    }
  }

  Future<void> nativeFrame() async {
    if (detached && lastNativeFrame != null) {
      await desktop.channel.invokeMethod<void>('frame', {
        'sid': sid,
        'bytes': lastNativeFrame,
      });
    }
  }

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
          await Future.any([
            detached
                ? Future<void>.delayed(const Duration(milliseconds: 16))
                : framePresented(),
            stop.future,
          ]);
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

  final clips = <int, Map<String, dynamic>>{};
  final blocks = <int, LinuxCopy>{};
  final _fetched = <int, LinuxCopy>{};
  int _nextItem = 1;
  final held = <int>{};
  int? selected;
  bool closed = false;
  bool disconnected = false;

  bool _sending = false;
  int _nextSeq = 1;
  final _pastes = <int, Completer<String>>{};
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
        if (piece is! Map) throw StateError('无效的输入内容');
        final copy = piece['text'] is String
            ? LinuxCopy(
                'text',
                text: piece['text'] as String,
                uti: 'public.utf8-plain-text',
              )
            : blocks[piece['block']];
        if (copy == null) throw StateError('附件已移除');
        if (closed || disconnected) throw StateError('A 已断开，未发送');
        if (_nextSeq > 0xffffffff || _nextItem > 0xffffffff) {
          throw StateError('请重新连接后发送');
        }
        final seq = _nextSeq++;
        final source = <String, Object?>{};
        final bytes = copy.kind == 'text'
            ? utf8.encode(copy.text!)
            : copy.bytes;
        if (copy.kind == 'text' && bytes!.length < 60000) {
          source['text'] = copy.text;
        } else {
          // Blocks keep their item number across cancel/retry so the host resumes.
          final item = piece['block'] as int? ?? _nextItem++;
          await transfers.upload(
            item: item,
            kind: copy.kind,
            uti: copy.uti,
            name: copy.files.isEmpty ? '' : copy.files.single.split('/').last,
            bytes: bytes,
            file: copy.files.firstOrNull,
          );
          source['item'] = item;
        }
        if (closed || disconnected) throw StateError('A 已断开，未发送');
        final reply = Completer<String>();
        _pastes[seq] = reply;
        try {
          if (selected != null) {
            send({'cmd': 'select_window', 'window': selected});
          }
          send({'cmd': 'paste', 'seq': seq, ...source});
          final error = await reply.future.timeout(
            const Duration(seconds: 15),
            onTimeout: () => '未收到 A 的确认，请检查远端内容后再重试',
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

  Future<LinuxCopy> fetch(int id) async {
    if (_fetched.containsKey(id)) return _fetched[id]!;
    final info = clips[id];
    if (info == null) throw StateError('unknown clip');
    final kind = info['kind'] as String;
    late final LinuxCopy result;
    if (kind == 'text') {
      result = LinuxCopy(
        'text',
        text: info['text'] as String,
        uti: 'public.utf8-plain-text',
      );
    } else if (kind == 'files') {
      final files = <String>[];
      final announced = info['files'] as List;
      for (var i = 0; i < announced.length; i++) {
        files.add(
          await transfers.download(
                clip: id,
                index: i,
                name: announced[i]['name'] as String,
                total: announced[i]['bytes'] as int,
                toDisk: true,
              )
              as String,
        );
      }
      result = LinuxCopy('files', files: files, uti: 'public.file-url');
    } else if (kind == 'image' || kind == 'data') {
      result = LinuxCopy(
        kind,
        uti: kind == 'image' ? 'public.png' : info['uti'] as String,
        bytes:
            await transfers.download(
                  clip: id,
                  index: 0,
                  name: kind == 'image' ? '图片' : '数据',
                  total: info['bytes'] as int,
                  toDisk: false,
                )
                as Uint8List,
      );
    } else {
      throw StateError(info['label'] as String? ?? '不支持这一项');
    }
    if (!closed) _fetched[id] = result;
    return result;
  }

  Future<Map<String, Object?>> insert(LinuxCopy? copy) async {
    if (copy == null || closed) return {};
    if (copy.kind == 'text' &&
        copy.text!.runes.length < 800 &&
        '\n'.allMatches(copy.text!).length < 9) {
      return {'text': copy.text};
    }
    final chips = <Map<String, Object>>[];
    final values = copy.kind == 'files'
        ? [
            for (final path in copy.files)
              LinuxCopy('files', files: [path], uti: 'public.file-url'),
          ]
        : [copy];
    String? status;
    for (final value in values) {
      if (value.kind == 'files' &&
          await FileSystemEntity.type(value.files.single) !=
              FileSystemEntityType.file) {
        status = '文件夹不支持，或文件已不存在';
        continue;
      }
      if (closed) break;
      final n = _nextItem++;
      blocks[n] = value;
      final label = switch (value.kind) {
        'text' => '[贴入文字 #$n +${'\n'.allMatches(value.text!).length + 1} 行]',
        'files' => '[文件 ${value.files.single.split('/').last}]',
        'image' => '[图片 #$n]',
        _ => '[数据 #$n ${value.uti}]',
      };
      chips.add({'n': n, 'label': label});
    }
    return {'blocks': chips, 'status': ?status};
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
            final id = m['id'] as int;
            final info = Map<String, dynamic>.from(
              m['info'] as Map? ??
                  {'kind': m['text'] == null ? 'unsupported' : 'text'},
            );
            info['text'] = m['text'];
            info['truncated'] = m['truncated'];
            if (info['kind'] == 'text') {
              unawaited(
                desktop
                    .writeClipboard(
                      LinuxCopy('text', text: info['text'] as String),
                    )
                    .catchError((Object _) => false),
              );
            }
            clips.remove(id);
            clips[id] = info;
            while (clips.length > 100) {
              final old = clips.keys.first;
              clips.remove(old);
              _fetched.remove(old);
            }
            emit(
              ClipsEvent(
                sid,
                clips.entries.toList().reversed.map((c) {
                  final kind = ClipKind.values.byName(
                    c.value['kind'] as String,
                  );
                  return ClipRow(
                    c.key,
                    clipTitle(c.value),
                    kind != ClipKind.unsupported,
                    kind,
                  );
                }).toList(),
              ),
            );
          } else {
            if (method == 'menu') nativeMenuTable = m['items'] as List;
            if (detached && method == 'menu') {
              await desktop.channel.invokeMethod<void>('menus', {
                'sid': sid,
                'items': m['items'],
              });
            }
            final e = parseSessionEvent(method, {...m, 'sid': sid});
            if (e is WindowsEvent) {
              nativeWindowTable = m['windows'] as List;
              await nativeWindows();
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
    lastNativeFrame = bytes;
    await nativeFrame();
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
    transfers.close();
    for (final reply in _pastes.values) {
      if (!reply.isCompleted) reply.complete('A 已断开，发送未确认；请检查远端内容后再重试');
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
    lastNativeFrame = null;
    if (detached) {
      unawaited(
        desktop.channel
            .invokeMethod<void>('attach', {'sid': sid})
            .catchError((Object _) {}),
      );
    }
    blocks.clear();
    _fetched.clear();
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

String clipTitle(Map<String, dynamic> info) => switch (info['kind']) {
  'text' =>
    (info['text'] as String)
        .replaceAll('\n', ' ')
        .characters
        .take(80)
        .toString(),
  'image' => '图片 ${info['width']}×${info['height']} · ${info['bytes']} B',
  'files' =>
    '${(info['files'] as List).length} 个文件 · ${(info['files'] as List).firstOrNull?['name'] ?? ''}',
  'data' => '数据 ${info['uti']} · ${info['bytes']} B',
  _ => info['label'] as String? ?? '不支持的内容',
};
