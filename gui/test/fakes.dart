import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:rapp/embed/composer_editor.dart';
import 'package:rapp/embed/session_port.dart';
import 'package:rapp/hub_client.dart';
import 'package:rapp/term/term_model.dart';
import 'package:rapp/term/term_session_port.dart';
import 'package:rapp/term/term_wire.dart';

/// In-memory [ComposerEditor]: the text is [value]; [inserted] logs every `insert`.
class FakeEditor implements ComposerEditor {
  String value = '';
  final inserted = <String>[];
  bool focused = false;

  /// The maxHeight the last [view] was handed.
  double? lastMaxHeight;

  /// A view that is as tall as the maxHeight it is handed (what a native editor does).
  bool selfSizing = false;

  @override
  EditorHandlers? handlers;

  @override
  Widget view(BuildContext context, {required EditorStyle style, required String hint, required double maxHeight}) {
    lastMaxHeight = maxHeight;
    return selfSizing ? SizedBox(key: const Key('fake-editor'), height: maxHeight) : const SizedBox();
  }

  @override
  void focus() => focused = true;

  @override
  void unfocus() => focused = false;

  /// The last [chips] labels.
  Map<int, String> labels = {};

  /// Where [insert] puts text (and moves on past it); null: at the end.
  int? caret;

  @override
  void chips(Map<int, String> labels) => this.labels = Map.of(labels);

  @override
  void setText(String text) => value = text;

  @override
  void insert(String text) {
    inserted.add(text);
    final at = caret;
    if (at == null) {
      value += text;
    } else {
      value = value.replaceRange(at, at, text);
      caret = at + text.length;
    }
  }

  /// [value] with each labelled mark shown as `[label]`.
  String get shown => String.fromCharCodes(value.codeUnits.expand((u) {
        final l = labels[u];
        return l == null ? [u] : '[$l]'.codeUnits;
      }));

  @override
  Future<String> read() async => value;

  @override
  bool get isEmpty => value.isEmpty;

  @override
  Future<String> take() async {
    final v = value;
    value = '';
    return v;
  }

  @override
  void dispose() {}
}

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

/// In-memory stand-in for the runner's `rapp/session` channel: records every call with its
/// channel arguments and lets a test play runner events.
class FakeSessionPort extends SessionPort {
  bool inlineNative = false;
  final nativeCalls = <(String, Map<String, Object?>)>[];
  @override
  bool get supportsInlineNativeComposer => inlineNative;
  @override
  void nativeHostNotice(Object sid, {required int epoch, required String text,
      required List<Map<String, String>> actions}) =>
      nativeCalls.add(('host_notice', {'sid': sid, 'epoch': epoch, 'text': text, 'actions': actions}));
  @override
  void nativeComposerInsert(Object sid, String? text, List<BlockChip> blocks) =>
      nativeCalls.add(('composer_insert', {'sid': sid, 'text': text, 'blocks': blocks}));
  @override
  void nativeComposerOptions(Object sid, {required bool allowed, required bool compose,
      required double scale, Map<String, Object> style = const {}}) =>
      nativeCalls.add(('composer_options', {'sid': sid, 'allowed': allowed, 'compose': compose, 'scale': scale, ...style}));
  final calls = <(String, Map<String, Object?>)>[];
  final _events = StreamController<SessionEvent>.broadcast(sync: true);

  /// When set, `start` throws it.
  Object? startError;

  /// When set, `start` waits for it to complete first.
  Completer<void>? startGate;
  int doubleClickMs = 500;

  /// What `composer_paste` and `composer_attach` answer (a runner `PasteResult` map).
  Map<String, Object?>? pasteReply;

  /// What `fetch_clip` answers; null means `{copy: <next number>}`. [fetchError] is thrown instead.
  Map<String, Object?>? fetchReply;
  Object? fetchError;
  bool copyLocalReply = true;

  /// What `pin_save` and `pin_load` answer; null means null.
  Map<String, Object?>? pinSaveReply;
  Map<String, Object?>? pinLoadReply;
  bool revealReply = true;
  int _nextCopy = 1;

  @override
  Stream<SessionEvent> get events => _events.stream;

  /// Pretend the runner sent [e].
  void emit(SessionEvent e) => _events.add(e);

  @override
  Future<Object?> invoke(String method, Map<String, Object?> args) async {
    calls.add((method, args));
    if (method == 'init') return {'doubleClickMs': doubleClickMs};
    if (method == 'start' && startGate != null) await startGate!.future;
    if (method == 'start' && startError != null) throw startError!;
    if (method == 'composer_paste' || method == 'composer_attach') return pasteReply;
    if (method == 'fetch_clip') {
      if (fetchError != null) throw fetchError!;
      return fetchReply ?? {'copy': _nextCopy++};
    }
    if (method == 'pin_save') return pinSaveReply;
    if (method == 'pin_load') return pinLoadReply;
    if (method == 'copy_local') return copyLocalReply;
    if (method == 'reveal') return revealReply;
    return null;
  }
}

/// A terminal port that never touches the network: records calls, and the test sets the model and panes.
class FakeTermSessionPort extends TermSessionPort {
  final calls = <(String, Map<String, Object?>)>[];
  final models = <Object, TermModel>{};
  final paneLists = <Object, List<TermPane>>{};
  final _owned = <Object>{};

  /// Pretend the worker made [sid] a terminal session with [panes].
  void seed(Object sid, {List<TermPane> panes = const [], TermModel? model}) {
    _owned.add(sid);
    paneLists[sid] = panes;
    models[sid] = model ?? TermModel();
  }

  /// Pretend a runner event.
  void play(SessionEvent e) => emit(e);

  /// The port's own writing-panel events go into [calls] too, as `composer`, in the order they are made.
  @override
  void emit(SessionEvent e) {
    if (e is ComposerStateEvent) {
      calls.add(('composer', {'sid': e.sid, 'sending': e.sending, 'sent': e.done?.sent, 'failure': e.done?.failure}));
    }
    super.emit(e);
  }

  @override
  Future<Object?> invoke(String method, Map<String, Object?> args) async {
    calls.add((method, args));
    final sid = args['sid'];
    if (sid == null) return null;
    if (method == 'start') seed(sid, panes: paneLists[sid] ?? const [], model: models[sid]);
    if (method == 'close') _owned.remove(sid);
    return null;
  }

  @override
  bool owns(Object sid) => _owned.contains(sid);
  @override
  TermModel? model(Object sid) => models[sid];
  @override
  List<TermPane> panes(Object sid) => paneLists[sid] ?? const [];
  @override
  TermPane? pane(Object sid, int window) => panes(sid).where((p) => p.number == window).firstOrNull;
  @override
  void view(Object sid, int window, int cols, int rows) {
    calls.add(('view', {'sid': sid, 'window': window, 'cols': cols, 'rows': rows}));
    lastCols = cols;
    lastRows = rows;
  }

  /// What [paste] answers (null: it went in).
  String? pasteReply;

  @override
  void sendKeys(Object sid, List<String> keys) => calls.add(('keys', {'sid': sid, 'keys': keys}));
  @override
  void type(Object sid, String text) => calls.add(('type', {'sid': sid, 'text': text}));
  /// When set, [paste] answers when it completes instead of with [pasteReply].
  Completer<String?>? pasteWait;

  @override
  Future<String?> paste(Object sid, String data, {bool enter = false}) async {
    calls.add(('paste', {'sid': sid, 'data': data, 'enter': enter}));
    final w = pasteWait;
    return w == null ? pasteReply : w.future;
  }

  @override
  void fetchHistory(Object sid) => calls.add(('fetchHistory', {'sid': sid}));
}
