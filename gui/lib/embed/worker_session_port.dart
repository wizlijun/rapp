// Linux uses the same Rust decoder as the standalone GTK client, in a headless
// child process. Binary pipes carry BGRA frames; no base64 or window reparenting.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'session_port.dart';
import 'state_rules.dart' show stateRulesLimit;
import 'modifier_latch.dart';
import 'voice_key_gate.dart';
import 'linux_transfer.dart';
import 'session_copy.dart';
import 'session_host.dart';
import 'session_link.dart';
import 'frame_sink.dart';

export 'session_worker.dart' show sessionPackets;

// Opt-in timing only. Never include input text, clipboard data, tokens or pixels.
void _streamTrace(SessionHost host, int worker, String stage, String detail) {
  if (host.traceDir == null) return;
  stderr.writeln(
    'stream-trace ${DateTime.now().microsecondsSinceEpoch} worker=$worker $stage $detail',
  );
}

class WorkerSessionPort extends SessionPort with WidgetsBindingObserver {
  WorkerSessionPort(
    this.links,
    this.host, {
    Future<void> Function()? framePresented,
    this.sink = const ImageFrameSink(),
  }) : _framePresented =
           framePresented ?? (() => SchedulerBinding.instance.endOfFrame);
  final Future<void> Function() _framePresented;
  final SessionLinks links;
  final SessionHost host;
  final FrameSink sink;
  final _events = StreamController<SessionEvent>.broadcast();
  final _sessions = <Object, _Session>{};
  final _starting = <Object>{};
  final _cancelledStarts = <Object>{};
  final _copies = <int, SessionCopy>{};
  int _nextCopy = 1;
  Object? _focused;
  final _voiceGate = VoiceKeyGate();
  final _voiceClock = Stopwatch()..start();
  Timer? _voiceTimer;
  KeyEvent? _voiceHeld;
  bool _voiceReady = false;

  VoiceGateStep _voiceFeed(VoiceGateInput input, {KeyEvent? event, int? ms}) {
    final sid = _focused;
    final session = _sessions[sid];
    final step = _voiceGate.handle(input, ms: ms ?? _voiceClock.elapsedMilliseconds,
        ready: _voiceReady && session != null && !session.secure && !session.closed && !session.disconnected);
    if (step.flush) {
      final held = _voiceHeld;
      _voiceHeld = null;
      _voiceTimer?.cancel();
      if (sid != null && held != null) _remoteKey(sid, held);
    }
    if (step.arm && event != null) {
      _voiceHeld = event;
      final at = _voiceClock.elapsedMilliseconds;
      _voiceTimer?.cancel();
      _voiceTimer = Timer(const Duration(milliseconds: 301), () {
        _voiceFeed(VoiceGateInput.elapsed, ms: at + 301);
      });
    }
    if (input == VoiceGateInput.resign) {
      _voiceTimer?.cancel();
      _voiceHeld = null;
    }
    if (sid != null && step.voice != null) {
      if (step.voice == VoiceKeyPhase.start) _voiceHeld = null;
      _emit(VoiceKeyEvent(sid, step.voice!));
    }
    return step;
  }

  /// A letter on the focused picture opens the writing panel with it (`picture_focus` `compose`).
  bool _compose = false;

  /// Compose letters taken off A: their repeats and releases are not A's either.
  final Set<PhysicalKeyboardKey> _swallowed = {};

  static final _letter = RegExp(r'^\p{L}$', unicode: true);

  /// A compose letter went to the draft and the panel has not taken the keys yet (no `picture_focus`
  /// since): what is typed in that gap (a space, a digit) follows the letter, not A.
  bool _composing = false;
  static final _printable = RegExp(r'^\P{C}$', unicode: true);
  bool _disposed = false;

  Object? _dropSid;
  @override
  bool get supportsDetach => host.supportsDetach;
  @override
  bool get supportsInlineNativeComposer => host.supportsInlineNativeComposer;
  @override
  Stream<SessionEvent> get events => _events.stream;

  @override
  Future<int> init() async {
    await links.check();
    await host.init(_nativeEvent);
    WidgetsBinding.instance.addObserver(this);
    return 500;
  }

  void _emit(SessionEvent e) {
    if (_disposed) return;
    final s = _sessions[e.sid];
    if (e.sid == _focused && ((e is SecureFocusEvent && e.on) || e is DisconnectedEvent)) {
      _voiceFeed(VoiceGateInput.resign);
    }
    if (host.supportsDetach && s?.detached == true) {
      if (e is SecureFocusEvent) {
        _nativeCall('secure_focus', {'sid': e.sid, 'on': e.on});
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
        _nativeCall('secure_focus', {'sid': e.sid, 'on': false});
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
      host.detachChannel
          ?.invokeMethod<void>(method, args)
          .catchError((Object _) {}),
    );
  }

  Future<Object?> _nativeEvent(MethodCall call) async {
    final args = Map<String, Object?>.from(call.arguments as Map? ?? {});
    final sid = args['sid'] ?? _dropSid;
    final s = _sessions[sid];
    if (s == null || s.closed) return null;
    args['sid'] = sid;
    if (call.method == 'window_visible') {
      final visible = args['visible'];
      if (s.detached && visible is bool) {
        s.windowVisible = visible;
        _emit(WindowVisibleEvent(s.sid, visible));
      }
    } else if (call.method == 'set_stream') {
      _emit(
        StreamChoiceEvent(
          s.sid,
          args['mode'] as String,
          args['density'] as String,
          args['fps'] as int,
          smart: args['smart'] == true,
        ),
      );
    } else if (call.method == 'host_notice_action') {
      if (args['action'] is String && args['epoch'] is int) {
        _emit(HostNoticeActionEvent(s.sid, args['action'] as String, args['epoch'] as int));
      }
    } else if (call.method == 'draft') {
      _emit(ComposerDraftEvent(s.sid, text: args['text'] as String?, inline: true));
    } else if (call.method == 'composer_send') {
      _emit(
        ComposerDraftEvent(s.sid, text: args['text'] as String?, inline: true, send: true),
      );
    } else if (call.method == 'composer_action') {
      _emit(ComposerDraftEvent(s.sid, text: args['text'] as String?, inline: true, action: args['action'] as String?));
    } else if (call.method == 'composer_retry') {
      _emit(ComposerDraftEvent(s.sid, retry: true));
    } else if (call.method == 'composer_drop_block') {
      _emit(ComposerDraftEvent(s.sid, drop: args['block'] as int?));
      await invoke(call.method, args);
    } else if (call.method == 'drop_files' ||
        call.method == 'composer_paste' ||
        call.method == 'composer_attach') {
      final result = call.method == 'drop_files'
          ? await s.insert(
              SessionCopy(
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
  void nativeComposerOptions(Object sid, {required bool allowed, required bool compose, required double scale, Map<String, Object> style = const {}}) {
    final s = _sessions[sid];
    if (s == null) return;
    s.composerOptions = {'sid': sid, 'allowed': allowed, 'compose': compose, 'scale': scale, ...style};
    if (s.detached) _nativeCall('composer_options', s.composerOptions);
  }

  @override
  void nativeComposerInsert(Object sid, String? text, List<BlockChip> blocks) {
    if (_sessions[sid]?.detached == true) {
      _nativeCall('composer_insert', {
        'sid': sid, 'text': text,
        'blocks': [for (final b in blocks) {'n': b.n, 'label': b.label, if (b.mark != null) 'mark': b.mark}],
      });
    }
  }

  @override
  void nativeHostNotice(Object sid, {required int epoch, required String text,
      required List<Map<String, String>> actions}) {
    if (_sessions[sid]?.detached == true) {
      _nativeCall('host_notice', {
        'sid': sid, 'epoch': epoch, 'text': text, 'actions': actions,
      });
    }
  }

  @override
  void nativeComposerDraft(Object sid, String text) {
    if (_sessions[sid]?.detached == true) _nativeCall('composer_draft', {'sid': sid, 'text': text});
  }

  @override
  void freeze(Object sid, String reason) => _sessions[sid]?.disconnect(reason);

  @override
  void dropTarget(Object? sid) {
    _dropSid = sid;
  }

  void _releaseFocus({bool clear = true}) {
    _voiceFeed(VoiceGateInput.resign);
    final s = _sessions[_focused];
    if (s != null) {
      for (final code in s.held.toList()) {
        s.send({'cmd': 'key', 'keyCode': code, 'modifiers': 0, 'down': false});
      }
      s.held.clear();
      s.latched = 0;
      s.strokeLatch.clear();
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
    final code = macKeyCode(event.physicalKey);
    if (code != null) {
      final input = event is KeyUpEvent ? VoiceGateInput.up(code)
          : VoiceGateInput.down(code, macFlags(HardwareKeyboard.instance), repeat: event is KeyRepeatEvent);
      if (!_voiceFeed(input, event: event).pass) return true;
    }
    return _remoteKey(sid, event);
  }

  /// A key-down (not a modifier alone, not a Command shortcut) while A is on an input method:
  /// switch A to English first, once (the same rule as the native session).
  void _englishFirst(_Session s, int code, int mods) {
    if (!s.autoEnglish || s.remoteAscii != false) return;
    if (code >= 54 && code <= 63) return;
    if (mods & (1 << 20) != 0) return;
    s.remoteAscii = true;
    s.send({'cmd': 'select_input', 'id': ''});
  }

  /// Test hook: A reported its input source.
  @visibleForTesting
  void inputSourceForTest(Object sid, bool ascii) => _sessions[sid]?.remoteAscii = ascii;

  bool _remoteKey(Object sid, KeyEvent event) {
    final s = _sessions[sid];
    if (s == null || s.closed || s.disconnected) return false;
    final keyboard = HardwareKeyboard.instance;
    // Super belongs to the Linux desktop. Ctrl maps to the remote Mac's Command.
    if (keyboard.isMetaPressed) return false;
    // Ctrl+Enter is rApp's (the writing panel), whatever the remote Command would have done.
    if ((event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        keyboard.isControlPressed &&
        !keyboard.isShiftPressed &&
        !keyboard.isAltPressed) {
      return false;
    }
    // type-to-compose: a plain letter goes into the draft, not to A (its repeats and release too).
    if (_swallowed.contains(event.physicalKey)) {
      if (event is KeyUpEvent) _swallowed.remove(event.physicalKey);
      return true;
    }
    final ch = event.character;
    // Never in a password field on A (v13 secure_focus): the keys go straight there.
    if (_compose &&
        !s.secure &&
        s.latched & (latchCtrl | latchOpt | latchCmd) == 0 &&
        event is KeyDownEvent &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        ch != null &&
        (_composing ? _printable : _letter).hasMatch(ch)) {
      _composing = true;
      _swallowed.add(event.physicalKey);
      _emit(ComposerInsertEvent(sid, PasteResult(text: ch), letter: true));
      return true;
    }
    final code = hidMacKeyCode(event.physicalKey);
    if (code == null) return false;
    final down = event is! KeyUpEvent;
    // A once latch belongs to the entire hardware stroke (repeat and release included).
    // Physical modifiers alone never consume it. AppKeySender rearms locked bits on latch_used.
    final useLatch = event is KeyDownEvent && !(code >= 54 && code <= 63) && s.latched != 0;
    if (event is KeyDownEvent) s.strokeLatch[code] = s.latched;
    final latched = s.strokeLatch[code] ?? s.latched;
    if (down) {
      s.held.add(code);
    } else {
      s.held.remove(code);
      s.strokeLatch.remove(code);
    }
    final mods =
        (keyboard.isShiftPressed ? 1 << 17 : 0) |
        (keyboard.isControlPressed ? 1 << 20 : 0) |
        (keyboard.isAltPressed ? 1 << 19 : 0) | latched;
    if (down) _englishFirst(s, code, mods);
    s.send({'cmd': 'key', 'keyCode': code, 'modifiers': mods, 'down': down});
    if (useLatch) {
      s.latched = 0;
      _emit(LatchUsedEvent(sid));
    }
    return true;
  }

  @override
  void setView(Object sid, int window, Rect rect, double zoom) {
    final s = _sessions[sid];
    if (s == null) return;
    if (!zoom.isFinite || zoom <= 0 ||
        ![rect.left, rect.top, rect.width, rect.height].every((n) => n.isFinite) ||
        (window != 0 && (rect.width <= 0 || rect.height <= 0))) {
      return;
    }
    s.viewWindow = window;
    s.viewRect = rect;
    s.viewZoom = zoom;
    s.send({'cmd': 'set_view', 'window': window, 'x': rect.left,
      'y': rect.top, 'w': rect.width, 'h': rect.height});
    _sendStream(s);
  }

  /// A focused session over [link] without the worker handshake. With
  /// [reading] the input watch and the read loop run, as after a real start.
  @visibleForTesting
  void seedSessionForTest(Object sid, SessionLink link, {bool reading = false}) {
    final s = _Session(sid, link, _emit, _framePresented, 0, '', host, sink);
    _sessions[sid] = s;
    _focused = sid;
    if (reading) _watch(sid, s);
  }

  void _watch(Object sid, _Session s) {
    unawaited(
      s.link.inputDone.catchError((Object _) {
        s.disconnect('session worker stopped');
      }),
    );
    unawaited(
      s.read().whenComplete(() {
        if (s.closed && identical(_sessions[sid], s)) _sessions.remove(sid);
        if (_focused == sid) _focused = null;
      }),
    );
  }

  /// Holds [text] as a copy without a session.
  @visibleForTesting
  int seedCopyForTest(String text) {
    final copy = _nextCopy++;
    _copies[copy] = SessionCopy(
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
      return copy != null && await host.writeClipboard(copy);
    }
    if (method == 'pin_save') {
      final copy = _copies[args['copy']];
      if (copy == null) return null;
      try {
        return {
          'path': await saveSessionCopy(
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
        final value = await loadSessionCopy(args['path'] as String);
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
      return host.reveal(path);
    }
    if (method == 'set_voice_hotkey') {
      final hotkey = VoiceHotkey.fromJson(args['hotkey']);
      if (hotkey != _voiceGate.hotkey) {
        _voiceTimer?.cancel();
        _voiceHeld = null;
        final phase = _voiceGate.setHotkey(hotkey).voice;
        if (phase != null && _focused != null) _emit(VoiceKeyEvent(_focused!, phase));
      }
      return null;
    }
    final sid = args['sid'];
    if (method == 'voice_end') {
      if (sid == _focused) _voiceFeed(VoiceGateInput.ended);
      return null;
    }
    if (method == 'picture_focus') {
      if (_focused != sid) {
        _releaseFocus();
        _swallowed.clear(); // their releases now go elsewhere
      }
      if (_voiceReady && args['voice'] != true) _voiceFeed(VoiceGateInput.resign);
      _focused = sid;
      _voiceReady = sid != null && args['voice'] == true;
      _compose = sid != null && args['compose'] == true;
      _composing = false;
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
      late final SessionLink link;
      try {
        link = await links.open();
      } catch (_) {
        _cancelledStarts.remove(sid);
        rethrow;
      } finally {
        _starting.remove(sid);
      }
      final cancelled = _cancelledStarts.remove(sid);
      if (_disposed || cancelled) {
        unawaited(link.packets.drain<void>());
        unawaited(link.close().catchError((Object _) {}));
        link.kill();
        throw StateError('Session start cancelled');
      }
      final s = _Session(
        sid,
        link,
        _emit,
        _framePresented,
        args['port'] as int,
        args['token'] as String,
        host,
        sink,
      );
      s.stream = {
        'mode': args['mode'],
        'fps': args['fps'],
        'density': args['density'],
      };
      _sessions[sid] = s;
      _watch(sid, s);
      s.send({'cmd': 'start', ...args, 'density': _density(args['density'])});
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
    if (!['close', 'attach', 'raise_detached', 'set_hidden', 'set_banner', 'composer_paste', 'composer_attach', 'composer_drop_block', 'composer_submitted'].contains(method) &&
        s.disconnected) {
      return null;
    }
    switch (method) {
      case 'detach':
        if (!host.supportsDetach || s.detached) return null;
        try {
          await host.detachChannel?.invokeMethod<void>('detach', {
            'sid': sid,
            'text': args['text'],
            'blocks': args['blocks'],
          });
          if (_disposed || s.closed || !identical(_sessions[sid], s)) {
            await host.detachChannel?.invokeMethod<void>('attach', {'sid': sid, 'discard': true});
            return null;
          }
          if (s.disconnected) throw StateError('连接已断开');
          s.detached = true;
          s.windowVisible = true;
          s.wakeRenderer();
          await s.nativeWindows();
          if (_disposed || s.closed || !identical(_sessions[sid], s)) return null;
          s.nativeClips();
          _nativeCall('stream', {'sid': sid, ...s.stream});
          await s.nativeFrame();
          if (_disposed || s.closed || !identical(_sessions[sid], s)) return null;
          s.nativeFocus();
          _nativeCall('secure_focus', {'sid': sid, 'on': s.secure});
          _nativeCall('composer_options', {'sid': sid, ...s.composerOptions});
          if (s.banner.isNotEmpty) _nativeCall('banner', {'sid': sid, 'text': s.banner});
          _emit(DetachedEvent(s.sid, true));
          _emit(WindowVisibleEvent(s.sid, s.windowVisible));
        } catch (_) {
          s.restoreStage();
          await host.detachChannel?.invokeMethod<void>('attach', {'sid': sid, 'discard': true}).catchError((Object _) {});
          rethrow;
        }
      case 'attach':
        if (!s.detached) return null;
        await host.detachChannel?.invokeMethod<void>('attach', {'sid': sid});
        s.restoreStage();
        _emit(DetachedEvent(s.sid, false, current: s.selected));
      case 'raise_detached':
        if (s.detached) _nativeCall('raise', {'sid': sid});
      case 'set_hidden':
        s.hidden = Set<int>.from(args['windows'] as List);
        await s.nativeWindows();
      case 'set_banner':
        s.banner = args['text'] as String;
        if (s.detached) _nativeCall('banner', {'sid': sid, 'text': s.banner});
      case 'composer_submitted':
        if (s.detached) _nativeCall(method, args);
      case 'close':
        if (_focused == sid) _releaseFocus();
        s.close('closed');
        _sessions.remove(sid);
      case 'set_stream':
        s.stream = {
          'mode': args['mode'],
          'fps': args['fps'],
          'density': args['density'],
          'smart': args['focus'] == true,
          'pinned': args['pinned'] == true,
        };
        s.focusWanted = args['focus'] == true;
        if (!s.focusWanted) s.focusRegion = null;
        s.nativeFocus();
        if (s.detached) _nativeCall('stream', {'sid': sid, ...s.stream});
        _sendStream(s);
      case 'select_window':
        s.selected = args['window'] as int;
        _dropSid = sid;
        s.send({'cmd': method, ...args});
      case 'mouse':
        if (sid == _focused && args['kind'] == 'down') _voiceFeed(VoiceGateInput.pointer);
        if (args['kind'] == 'down') s.selected = args['window'] as int;
        s.send({'cmd': method, ...args});
      case 'scroll':
        if (sid == _focused) _voiceFeed(VoiceGateInput.scroll);
        s.send({'cmd': method, ...args});
      case 'key':
      case 'key_event':
        // The worker's key command uses an optional down flag for a single edge.
        if (args['down'] != false && args['keyCode'] is int) {
          _englishFirst(s, args['keyCode'] as int, (args['modifiers'] as int?) ?? 0);
        }
        s.send({...args, 'cmd': 'key'});
      case 'auto_english':
        s.autoEnglish = args['on'] as bool;
      case 'latch':
        s.latched = (args['modifiers'] as int) & (latchCmd | latchOpt | latchCtrl | latchShift);
      case 'resize':
      case 'menu_pick':
      case 'close_window':
      case 'select_input':
      case 'unlock':
      case 'dismiss_cover':
        s.send({'cmd': method, ...args});
      case 'state_rules':
        // The session process drops the link on a bad command: an oversized pack never goes out.
        final json = args['json'];
        if (json is String && utf8.encode(json).length <= stateRulesLimit) s.send({'cmd': method, 'json': json});
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
          return await s.insert(await host.readClipboard());
        } catch (e) {
          return {'status': '粘贴没成功：$e'};
        }
      case 'composer_attach':
        try {
          return await s.insert(
            SessionCopy('files', files: await host.chooseFiles()),
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
            await host.writeClipboard(copy);
          }
        } catch (e) {
          s.showStatus(
            '取用没成功：${e is StateError && e.message == 'unknown clip'
                ? '太旧了，远端已不保留'
                : e is StateError
                ? e.message
                : e}',
          );
        }
    }
    return null;
  }

  void _sendStream(_Session s) {
    final choice = s.stream['density'];
    final base = _density(choice);
    final window = s.windows.where((w) => w.id == s.viewWindow).firstOrNull;
    final density = window == null || s.viewWindow == 0 ? base : linuxViewDensity(
      base: base, original: choice == 'original', zoom: s.viewZoom,
      content: Size(window.rect.width, window.rect.height - window.titleBar),
      range: s.viewRect.size,
    );
    s.send({'cmd': 'set_stream', ...s.stream, 'density': density,
      'focus': s.focusWanted});
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

@visibleForTesting
double linuxViewDensity({required double base, required bool original,
    required double zoom, required Size content, required Size range}) {
  final area = content.width * content.height;
  final viewed = range.width * range.height;
  if (area <= 0 || viewed <= 0) return base;
  final desired = original ? 8.0 : (base * zoom).clamp(0.01, 8.0);
  return math.min(desired, base * math.sqrt(area / viewed)).clamp(0.01, 8).toDouble();
}

class _Session {
  _Session(
    this.sid,
    this.link,
    this.emit,
    this.framePresented,
    this.port,
    this.token,
    this.host,
    this.sink,
  ) {
    transfers = LinuxTransfers(
      port,
      token,
      downloads: host.downloads,
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
  final SessionHost host;
  bool detached = false;
  bool windowVisible = true;
  Map<String, Object?> composerOptions = {};
  Set<int> hidden = {};
  String banner = '';
  bool focusWanted = false;
  FocusRegionEvent? focusRegion;
  void nativeFocus() {
    if (!detached) return;
    final f = focusWanted ? focusRegion : null;
    unawaited(host.detachChannel?.invokeMethod<void>('focus', {
      'sid': sid, 'window': f?.window ?? 0,
      'rects': [for (final r in f?.rects ?? <ui.Rect>[]) [r.left, r.top, r.width, r.height]],
    }).catchError((Object _) {}));
  }
  Map<String, Object?> stream = {
    'mode': 'color16',
    'density': 'adaptive',
    'fps': 15,
  };
  void nativeClips() {
    if (detached) {
      unawaited(
        host.detachChannel
            ?.invokeMethod<void>('clips', {
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
    if (detached && !closed) {
      await host.detachChannel?.invokeMethod<void>('windows', {
        'sid': sid,
        'windows': [for (final w in nativeWindowTable) if (!hidden.contains(w['id'])) w],
      });
      if (closed) return;
      await host.detachChannel?.invokeMethod<void>('menus', {
        'sid': sid,
        'items': nativeMenuTable,
      });
    }
  }

  Future<void> nativeFrame() async {
    if (detached && !closed && lastNativeFrame != null) {
      await host.detachChannel?.invokeMethod<void>('frame', {
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
  final SessionLink link;
  final FrameSink sink;
  final void Function(SessionEvent) emit;
  List<RemoteWindow> windows = [];
  int viewWindow = 0;
  Rect viewRect = Rect.zero;
  double viewZoom = 1;
  final _pictures = <int, RemoteWindow>{};
  Uint8List? _pendingFrame;
  // The mailbox frame came off the link and is not acked yet.
  bool _pendingAck = false;
  int _receivedFrames = 0;
  int _pendingSequence = 0;
  bool _restorePending = false;
  bool _rendering = false;
  Completer<void>? _renderWait;

  void wakeRenderer() {
    final wait = _renderWait;
    if (wait != null && !wait.isCompleted) wait.complete();
  }

  void restoreStage() {
    detached = false;
    wakeRenderer();
    // Prefer an already queued newer canvas. Restoring also works when the
    // remote is idle or disconnected and will not send another frame.
    final bytes = _pendingFrame ?? lastNativeFrame;
    if (!closed && bytes != null) queueFrame(bytes, restore: true);
  }

  void queueFrame(Uint8List bytes, {bool restore = false, bool fromLink = false}) {
    // Latest-frame mailbox: decoding/display must never block control events.
    // The frame it pushes out is dropped for good: ack it now.
    if (_pendingAck) link.ack();
    _pendingAck = fromLink;
    _pendingFrame = bytes;
    _restorePending = restore;
    _pendingSequence = ++_receivedFrames;
    _streamTrace(
      host,
      link.id,
      'pipe-frame',
      'output=$_pendingSequence bytes=${bytes.length}',
    );
    if (!_rendering) unawaited(drainFrames());
  }

  Future<void> drainFrames() async {
    _rendering = true;
    try {
      while (!closed && (!disconnected || _restorePending) && _pendingFrame != null) {
        final bytes = _pendingFrame!;
        final sequence = _pendingSequence;
        final restore = _restorePending;
        final ack = _pendingAck;
        _restorePending = false;
        _pendingAck = false;
        _pendingFrame = null;
        _streamTrace(host, link.id, 'image-start', 'output=$sequence');
        try {
          await frame(bytes, restore: restore);
        } finally {
          // Drawn, skipped or failed: the bytes are used up.
          if (ack) link.ack();
        }
        _streamTrace(host, link.id, 'image-ready', 'output=$sequence');
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
          _streamTrace(host, link.id, 'flutter-frame', 'output=$sequence');
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
  final blocks = <int, SessionCopy>{};
  final _fetched = <int, SessionCopy>{};
  int _nextItem = 1;
  final held = <int>{};
  int latched = 0;
  final strokeLatch = <int, int>{};
  int? selected;
  bool closed = false;
  bool disconnected = false;

  /// Whether A's input source is ASCII (null: never reported); set true after we switch it.
  bool? remoteAscii;
  bool autoEnglish = true;
  /// A's focus is in a password field (v13 secure_focus): no type-to-compose.
  bool secure = false;

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
            ? SessionCopy(
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

  Future<SessionCopy> fetch(int id) async {
    if (_fetched.containsKey(id)) return _fetched[id]!;
    final info = clips[id];
    if (info == null) throw StateError('unknown clip');
    final kind = info['kind'] as String;
    late final SessionCopy result;
    if (kind == 'text') {
      result = SessionCopy(
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
      result = SessionCopy('files', files: files, uti: 'public.file-url');
    } else if (kind == 'image' || kind == 'data') {
      result = SessionCopy(
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

  Future<Map<String, Object?>> insert(SessionCopy? copy) async {
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
              SessionCopy('files', files: [path], uti: 'public.file-url'),
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
    if (!closed && !disconnected) link.send(jsonEncode(args));
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
      await for (final packet in link.packets) {
        if (closed || disconnected) {
          if (packet[0] == 1) link.ack();
          break;
        }
        if (packet[0] == 1) {
          queueFrame(Uint8List.sublistView(packet, 1), fromLink: true);
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
                host
                    .writeClipboard(
                      SessionCopy('text', text: info['text'] as String),
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
              await host.detachChannel?.invokeMethod<void>('menus', {
                'sid': sid,
                'items': m['items'],
              });
            }
            final e = parseSessionEvent(method, {...m, 'sid': sid});
            if (e is InputSourceEvent) remoteAscii = e.ascii;
            if (e is WindowsEvent) {
              nativeWindowTable = m['windows'] as List;
              await nativeWindows();
              final f = focusRegion;
              if (f != null) {
                final old = windows.where((w) => w.id == f.window).firstOrNull;
                final now = e.windows.where((w) => w.id == f.window).firstOrNull;
                if (now == null || old?.rect.size != now.rect.size) {
                  focusRegion = null;
                  nativeFocus();
                }
              }
              windows = e.windows;
              for (final id in _pictures.keys.toList()) {
                if (!windows.any((w) => w.id == id)) {
                  sink.retire(_pictures.remove(id)?.image);
                }
              }
              if (!windows.any((w) => w.id == selected)) {
                selected = windows.where((w) => w.decorated).firstOrNull?.id;
              }
              publish();
            } else if (e != null) {
              if (e is FocusRegionEvent && focusWanted) {
                focusRegion = e;
                nativeFocus();
              }
              if (e is SecureFocusEvent) secure = e.on;
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

  Future<void> frame(Uint8List bytes, {bool restore = false}) async {
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
    // Detached windows draw this canvas themselves. Building another full
    // Flutter image here copies/uploads pixels for a stage that is not visible.
    if (closed || detached || (disconnected && !restore)) return;
    ui.Image? image;
    try {
      image = await sink.decode(Uint8List.sublistView(bytes, 24), width, height);
      if (closed || detached || (disconnected && !restore)) return;
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
            sink.retire(old.image);
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
        sink.retire(frames.value?.image);
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
      if (!reply.isCompleted) reply.complete('远端已断开，发送未确认；请检查远端内容后再重试');
    }
    held.clear();
    if (_pendingAck) link.ack();
    _pendingAck = false;
    _pendingFrame = null;
    _restorePending = false;
    _closed.complete();
    wakeRenderer();
    unawaited(link.close().catchError((Object _) {}));
    // EOF wakes the worker even if the host stopped producing frames.
    final timer = Timer(
      const Duration(seconds: 2),
      () => link.kill(),
    );
    unawaited(link.exitCode.then((_) => timer.cancel()));
  }

  void close(String reason) {
    if (closed) return;
    closed = true;
    _stopTransport();
    for (final p in _pictures.values) {
      sink.retire(p.image);
    }
    _pictures.clear();
    lastNativeFrame = null;
    if (detached) {
      unawaited(
        host.detachChannel
            ?.invokeMethod<void>('attach', {'sid': sid, 'discard': true})
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
int? hidMacKeyCode(PhysicalKeyboardKey key) {
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
