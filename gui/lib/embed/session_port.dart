// The Dart side of the `rapp/session` method channel (macOS only): calls into the runner's
// SessionPlugin, and the events it sends back. Arguments are maps; `sid` is the hub's sid.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A window's kind on A, with the same names as RappCore's `WindowKind`.
enum WindowKind {
  normal,
  dialog,
  floating,
  sheet,
  popover,
  menu,
  tooltip;

  /// Normal, dialog and floating windows have a title bar and get a tab; the rest are popups.
  bool get decorated => this == normal || this == dialog || this == floating;
}

/// One A window as the runner reports it.
class RemoteWindow {
  const RemoteWindow({
    required this.id,
    required this.parent,
    required this.kind,
    required this.title,
    required this.rect,
    required this.titleBar,
    required this.resizable,
    required this.focused,
    required this.texture,
    required this.visible,
    ui.Image? image,
    Rect? source,
    this.frames,
  // Keep public named arguments while the backing fields remain private.
  // ignore: prefer_initializing_formals
  }) : _image = image, _source = source;

  final int id;

  /// The window a popup belongs to; 0 for none.
  final int parent;
  final WindowKind kind;
  final String title;

  /// On A's canvas, in points, title bar included.
  final Rect rect;
  final double titleBar;
  final bool resizable;
  final bool focused;

  /// The Flutter texture showing this window; null if the runner has none for it.
  final int? texture;

  /// Linux frames share a decoded canvas image, cropped to this window.
  final ui.Image? _image;
  final Rect? _source;
  final ValueNotifier<WindowFrame?>? frames;
  ui.Image? get image => frames?.value?.image ?? _image;
  Rect? get source => frames?.value?.source ?? _source;
  bool get hasPicture => texture != null || image != null;

  /// The part of the window's content the texture shows, 0–1 from the top-left.
  final Rect visible;

  bool get decorated => kind.decorated;
}

/// Pixel updates are separate from window/session metadata and never rebuild the shell.
class WindowFrame {
  const WindowFrame(this.image, this.source);
  final ui.Image image;
  final Rect source;
}

/// One entry of A's clipboard history.
class ClipRow {
  const ClipRow(this.id, this.title, this.pickable, [ClipKind? kind])
      : kind = kind ?? (pickable ? ClipKind.text : ClipKind.unsupported);
  final int id;
  final String title;
  final bool pickable;
  final ClipKind kind;
}

/// What a clipboard entry holds.
enum ClipKind { text, image, files, data, unsupported }

/// One item of A's mirrored menu bar; `shortcut` is ready-made text like "⇧⌘S".
class MenuEntry {
  const MenuEntry({
    required this.title,
    this.enabled = true,
    this.checked = false,
    this.separator = false,
    this.shortcut,
    this.children = const [],
  });
  final String title;
  final bool enabled;
  final bool checked;
  final bool separator;
  final String? shortcut;
  final List<MenuEntry> children;
}

/// A composer block held by the runner (pasted image, long text, file…), shown as a chip.
class BlockChip {
  const BlockChip(this.n, this.label);
  final int n;
  final String label;
}

/// What a composer paste or attach produced: text to insert, blocks to add, a status to show,
/// or nothing.
class PasteResult {
  const PasteResult({this.text, this.blocks = const [], this.status});
  final String? text;
  final List<BlockChip> blocks;
  final String? status;
}

/// A composer send finished: `sent` pieces went out, then `failure` if one failed.
class ComposerDone {
  const ComposerDone(this.sent, this.failure);
  final int sent;
  final String? failure;
}

/// `start`'s arguments: the hub's sid, port and token, and the starting stream choice.
class StartArgs {
  const StartArgs(this.sid, this.port, this.token, this.mode, this.fps, this.density);
  final Object sid;
  final int port;
  final String token;

  /// `duogray|duocolor|color16|gray4|color8`.
  final String mode;
  final int fps;

  /// `saver1x|adaptive|original`.
  final String density;
}

sealed class SessionEvent {
  const SessionEvent(this.sid);
  final Object sid;
}

class ReadyEvent extends SessionEvent {
  const ReadyEvent(super.sid, this.appName);
  final String appName;
}

class WindowsEvent extends SessionEvent {
  const WindowsEvent(super.sid, this.windows);

  /// Front to back, as A gives them.
  final List<RemoteWindow> windows;
}

class TrafficEvent extends SessionEvent {
  const TrafficEvent(super.sid, this.bytes, [this.frames = 0]);

  /// Bytes received in the last second.
  final int bytes;

  /// Picture frames received in the last second.
  final int frames;
}

class DisconnectedEvent extends SessionEvent {
  const DisconnectedEvent(super.sid, this.reason);

  /// The raw reason the link ended; `''` if none was given.
  final String reason;
}

class ClipsEvent extends SessionEvent {
  const ClipsEvent(super.sid, this.clips);

  /// Newest first.
  final List<ClipRow> clips;
}

class MenuEvent extends SessionEvent {
  const MenuEvent(super.sid, this.items);
  final List<MenuEntry> items;
}

/// The composer started or stopped sending (`sending`), or finished a send (`done`).
class ComposerStateEvent extends SessionEvent {
  const ComposerStateEvent(super.sid, {this.sending, this.done});
  final bool? sending;
  final ComposerDone? done;
}

/// Something to put into the composer (a clipboard entry's "insert").
class ComposerInsertEvent extends SessionEvent {
  const ComposerInsertEvent(super.sid, this.insert);
  final PasteResult insert;
}

/// File transfer status text; null when idle.
class TransferStatusEvent extends SessionEvent {
  const TransferStatusEvent(super.sid, this.status);
  final String? status;
}

enum TransferState { running, done, failed, cancelled }

/// One numbered transfer's progress; `down` is A to B.
class TransferProgressEvent extends SessionEvent {
  const TransferProgressEvent(
      super.sid, this.id, this.down, this.name, this.done, this.total, this.state, this.path, this.error,
      {this.kind});
  final int id;
  final bool down;

  /// The file name; empty for an upload that is not a file.
  final String name;
  final int done;
  final int total;
  final TransferState state;
  final String? path;
  final String? error;

  /// Only on uploads: what is sent. Only [ClipKind.files] lands in A's <data root>/files/transfers.
  final ClipKind? kind;
}

/// The session moved into its own windows, or back; `current` is the window to show on return.
class DetachedEvent extends SessionEvent {
  const DetachedEvent(super.sid, this.detached, {this.current});
  final bool detached;
  final int? current;
}

/// The runner ended the session (its textures are already gone).
/// Input was refused because another device runs the session; [by] is '' for an unnamed one.
class InputBlockedEvent extends SessionEvent {
  const InputBlockedEvent(super.sid, this.by);
  final String by;
}

/// A's keyboard input source now (v8 hosts only). [ascii]: a plain keyboard layout, typing goes
/// straight through; false for an input method (Pinyin…), which may compose what A gets.
class InputSourceEvent extends SessionEvent {
  const InputSourceEvent(super.sid, this.id, this.name, this.ascii);
  final String id;
  final String name;
  final bool ascii;
}

class ClosedEvent extends SessionEvent {
  const ClosedEvent(super.sid, this.reason);
  final String reason;
}

class _Bad implements Exception {
  const _Bad();
}

T _as<T>(Object? v) => v is T ? v : throw const _Bad();

Map<Object?, Object?> _map(Object? v) => _as<Map<Object?, Object?>>(v);

List<Object?> _list(Object? v) => _as<List<Object?>>(v);

double _double(Object? v) {
  final d = _as<num>(v).toDouble();
  return d.isFinite ? d : throw const _Bad();
}

WindowKind _kind(Object? v) {
  final name = _as<String>(v);
  return WindowKind.values.firstWhere((k) => k.name == name, orElse: () => throw const _Bad());
}

RemoteWindow _window(Object? v) {
  final m = _map(v);
  final visible = _list(m['visible']).map(_double).toList();
  if (visible.length != 4) throw const _Bad();
  return RemoteWindow(
    id: _as<int>(m['id']),
    parent: _as<int>(m['parent']),
    kind: _kind(m['kind']),
    title: _as<String>(m['title']),
    rect: Rect.fromLTWH(_double(m['x']), _double(m['y']), _double(m['w']), _double(m['h'])),
    titleBar: _double(m['titleBar']),
    resizable: _as<bool>(m['resizable']),
    focused: _as<bool>(m['focused']),
    texture: _as<int?>(m['texture']),
    visible: Rect.fromLTWH(visible[0], visible[1], visible[2], visible[3]),
  );
}

MenuEntry _menuEntry(Object? v) {
  final m = _map(v);
  final shortcut = _as<String?>(m['shortcut']);
  return MenuEntry(
    title: _as<String>(m['title']),
    enabled: _as<bool>(m['enabled']),
    checked: _as<bool>(m['checked']),
    separator: _as<bool>(m['separator']),
    shortcut: shortcut == null || shortcut.isEmpty ? null : shortcut,
    children: _list(m['children']).map(_menuEntry).toList(),
  );
}

PasteResult _paste(Map<Object?, Object?> m) => PasteResult(
      text: _as<String?>(m['text']),
      blocks: m['blocks'] == null
          ? const []
          : _list(m['blocks']).map((b) {
              final bm = _map(b);
              return BlockChip(_as<int>(bm['n']), _as<String>(bm['label']));
            }).toList(),
      status: _as<String?>(m['status']),
    );

/// The event for one runner call; null for unknown methods and bad data (never throws).
SessionEvent? parseSessionEvent(String method, Object? args) {
  try {
    final m = _map(args);
    final Object sid = _as<Object>(m['sid']);
    switch (method) {
      case 'ready':
        return ReadyEvent(sid, _as<String>(m['appName']));
      case 'windows':
        return WindowsEvent(sid, _list(m['windows']).map(_window).toList());
      case 'traffic':
        return TrafficEvent(sid, _as<int>(m['bytes']), _as<int?>(m['frames']) ?? 0);
      case 'disconnected':
        return DisconnectedEvent(sid, _as<String?>(m['reason']) ?? '');
      case 'clipboard':
        return ClipsEvent(sid, _list(m['clips']).map((c) {
          final cm = _map(c);
          final pickable = _as<bool>(cm['pickable']);
          final k = cm['kind'];
          final kind = ClipKind.values.where((v) => v.name == k).firstOrNull;
          return ClipRow(_as<int>(cm['id']), _as<String>(cm['title']), pickable, kind);
        }).toList());
      case 'menu':
        return MenuEvent(sid, _list(m['items']).map(_menuEntry).toList());
      case 'composer':
        final sending = _as<bool?>(m['sending']);
        final done = m['done'] == null ? null : _map(m['done']);
        if (sending == null && done == null) return null;
        return ComposerStateEvent(sid,
            sending: sending,
            done: done == null ? null : ComposerDone(_as<int>(done['sent']), _as<String?>(done['failure'])));
      case 'composer_insert':
        if (m['text'] == null && m['blocks'] == null && m['status'] == null) return null;
        return ComposerInsertEvent(sid, _paste(m));
      case 'transfer_status':
        return TransferStatusEvent(sid, _as<String?>(m['status']));
      case 'transfer':
        final dir = _as<String>(m['dir']);
        if (dir != 'down' && dir != 'up') return null;
        final state = TransferState.values.where((v) => v.name == m['state']).firstOrNull;
        if (state == null) return null;
        return TransferProgressEvent(sid, _as<int>(m['id']), dir == 'down', _as<String>(m['name']),
            _as<int>(m['done']), _as<int>(m['total']), state, _as<String?>(m['path']), _as<String?>(m['error']),
            kind: ClipKind.values.where((v) => v.name == m['kind']).firstOrNull);
      case 'detached':
        return DetachedEvent(sid, _as<bool>(m['detached']), current: _as<int?>(m['current']));
      case 'input_blocked':
        return InputBlockedEvent(sid, _as<String?>(m['by']) ?? '');
      case 'input_source':
        return InputSourceEvent(sid, _as<String>(m['id']), _as<String>(m['name']), _as<bool>(m['ascii']));
      case 'closed':
        return ClosedEvent(sid, _as<String>(m['reason']));
    }
  } on _Bad {
    return null;
  }
  return null;
}

/// The runner's embedded sessions. Every method is one channel call with the same name in
/// snake case; [invoke] carries it (the real channel, or a fake that records it).
abstract class SessionPort {
  bool get supportsDetach => true;
  bool handleKeyEvent(Object sid, KeyEvent event) => false;
  void dispose() {}
  Stream<SessionEvent> get events;

  @protected
  Future<Object?> invoke(String method, Map<String, Object?> args);

  void _send(String method, Map<String, Object?> args) {
    // Fire and forget: the runner ignores calls for sessions it no longer has.
    unawaited(invoke(method, args).then<void>((_) {}, onError: (Object _) {}));
  }

  /// Must come first (textures register only after it); returns the double-click interval in ms.
  Future<int> init() async {
    final r = await invoke('init', const {});
    final ms = r is Map ? r['doubleClickMs'] : null;
    return ms is int ? ms : 500;
  }

  /// Connects to the hub's local port for this session; throws if the runner refuses.
  Future<void> start(StartArgs a) async {
    await invoke('start', {
      'sid': a.sid, 'port': a.port, 'token': a.token, 'mode': a.mode, 'fps': a.fps, 'density': a.density,
    });
  }

  void close(Object sid) => _send('close', {'sid': sid});

  /// `kind`: `down|up|drag|move`; `button`: `left|right`; A points from the window's top-left.
  void mouse(Object sid, int window, String kind, String button, double x, double y, int clicks) =>
      _send('mouse', {'sid': sid, 'window': window, 'kind': kind, 'button': button, 'x': x, 'y': y, 'clicks': clicks});

  void scroll(Object sid, int window, double x, double y, double dx, double dy) =>
      _send('scroll', {'sid': sid, 'window': window, 'x': x, 'y': y, 'dx': dx, 'dy': dy});

  /// A press and a release of one key (macOS key code, CGEventFlags modifiers).
  void key(Object sid, int keyCode, int modifiers) =>
      _send('key', {'sid': sid, 'keyCode': keyCode, 'modifiers': modifiers});

  /// The session whose picture has keyboard focus; null for none.
  void pictureFocus(Object? sid) => _send('picture_focus', {'sid': sid});

  void resize(Object sid, int window, int w, int h) =>
      _send('resize', {'sid': sid, 'window': window, 'w': w, 'h': h});

  void selectWindow(Object sid, int window) => _send('select_window', {'sid': sid, 'window': window});

  void setStream(Object sid, String mode, int fps, String density) =>
      _send('set_stream', {'sid': sid, 'mode': mode, 'fps': fps, 'density': density});

  void moveTopLeft(Object sid, int window) => _send('move_top_left', {'sid': sid, 'window': window});

  /// Presses A window [window]'s close button (a child window; not the session's end).
  void closeWindow(Object sid, int window) => _send('close_window', {'sid': sid, 'window': window});

  /// Switches A's input source to [id]; '' is the plain English (ASCII) keyboard layout.
  void selectInput(Object sid, String id) => _send('select_input', {'sid': sid, 'id': id});

  void menuPick(Object sid, List<int> path) => _send('menu_pick', {'sid': sid, 'path': path});

  void clipPick(Object sid, int clip, bool insert) =>
      _send('clip_pick', {'sid': sid, 'clip': clip, 'insert': insert});

  Future<PasteResult> composerPaste(Object sid) => _pasteCall('composer_paste', sid);

  Future<PasteResult> composerAttach(Object sid) => _pasteCall('composer_attach', sid);

  Future<PasteResult> _pasteCall(String method, Object sid) async {
    try {
      final r = await invoke(method, {'sid': sid});
      return r is Map ? _paste(_map(r)) : const PasteResult();
    } on _Bad {
      return const PasteResult();
    } on PlatformException {
      return const PasteResult();
    } on MissingPluginException {
      return const PasteResult();
    }
  }

  /// `pieces`: `{'text': …}` or `{'block': n}`, in send order.
  void composerSend(Object sid, List<Map<String, Object>> pieces) =>
      _send('composer_send', {'sid': sid, 'pieces': pieces});

  void composerDropBlock(Object sid, int block) => _send('composer_drop_block', {'sid': sid, 'block': block});

  /// One transfer (`id`), or all of the session's when null.
  void cancelTransfer(Object sid, {int? id}) =>
      _send('cancel_transfer', {'sid': sid, 'id': ?id});

  /// Fetches A's clip `clip` into a copy held by the runner; the copy's number, or why not.
  Future<({int? copy, String? error})> fetchClip(Object sid, int clip) async {
    const down = (copy: null, error: '没有连上 runner');
    try {
      final r = await invoke('fetch_clip', {'sid': sid, 'clip': clip});
      if (r is! Map) return down;
      final copy = r['copy'];
      if (copy is int) return (copy: copy, error: null);
      final error = r['error'];
      return error is String ? (copy: null, error: error) : down;
    } on PlatformException {
      return down;
    } on MissingPluginException {
      return down;
    }
  }

  /// Puts the copy on this Mac's clipboard; false if it is gone.
  Future<bool> copyLocal(int copy) => _boolCall('copy_local', {'copy': copy});

  /// Writes copy `copy` into the data dir (text under [textDir], everything else under [fileDir]);
  /// the path written, or null if it could not be.
  Future<String?> savePin(int copy, {required String textDir, required String fileDir, required String stem}) async {
    try {
      final r = await invoke('pin_save', {'copy': copy, 'text_dir': textDir, 'file_dir': fileDir, 'stem': stem});
      final path = r is Map ? r['path'] : null;
      return path is String ? path : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Reads a saved copy at [path] back into a new copy held by the runner; null if it cannot be read.
  Future<({int copy, ClipKind kind})?> loadPin(String path) async {
    try {
      final r = await invoke('pin_load', {'path': path});
      if (r is! Map) return null;
      final copy = r['copy'];
      final kind = const {
        'text': ClipKind.text,
        'image': ClipKind.image,
        'files': ClipKind.files,
        'data': ClipKind.data,
      }[r['kind']];
      return copy is int && kind != null ? (copy: copy, kind: kind) : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  void dropCopy(int copy) => _send('drop_copy', {'copy': copy});

  /// Shows the file in Finder; false if it is gone.
  Future<bool> reveal(String path) => _boolCall('reveal', {'path': path});

  Future<bool> _boolCall(String method, Map<String, Object?> args) async {
    try {
      return await invoke(method, args) == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  void detach(Object sid) => _send('detach', {'sid': sid});

  void attach(Object sid) => _send('attach', {'sid': sid});

  void raiseDetached(Object sid) => _send('raise_detached', {'sid': sid});

  void setHidden(Object sid, List<int> windows) => _send('set_hidden', {'sid': sid, 'windows': windows});
}

/// The real port: the `rapp/session` channel to the macOS runner's SessionPlugin.
class ChannelSessionPort extends SessionPort {
  ChannelSessionPort([MethodChannel channel = const MethodChannel('rapp/session')]) : _channel = channel {
    _channel.setMethodCallHandler((call) async {
      final e = parseSessionEvent(call.method, call.arguments);
      if (e != null) _events.add(e);
    });
  }

  final MethodChannel _channel;
  final _events = StreamController<SessionEvent>.broadcast();

  @override
  Stream<SessionEvent> get events => _events.stream;

  @override
  Future<Object?> invoke(String method, Map<String, Object?> args) => _channel.invokeMethod<Object?>(method, args);
}
