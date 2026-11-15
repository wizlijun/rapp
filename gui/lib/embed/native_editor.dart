// The macOS writing surface. NSTextView owns text, selection, undo and IME composition.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'composer_editor.dart';

class NativeEditor implements ComposerEditor {
  NativeEditor({required this.onToggleFocus, this.onShortcut}) {
    _channel.setMethodCallHandler(_event);
  }

  static int _nextId = 0;
  final _id = _nextId++;
  late final _channel = MethodChannel('rapp/composer/editor-$_id');

  final VoidCallback onToggleFocus;
  final ValueChanged<String>? onShortcut;
  @override
  EditorHandlers? handlers;

  final _ready = Completer<MethodChannel>();
  final _height = ValueNotifier<double>(48);
  bool _empty = true, _disposed = false, _wantFocus = false, _surfaceMounted = false;
  Future<void> _tail = Future.value();
  Future<void> _focusRequest = Future.value();

  // Commands are enqueued before the platform view is ready. Native text commands also queue
  // behind marked text, so read/take never overtake a pending set/insert.
  Future<T?> _text<T>(String method, [String? value]) {
    final result = _tail.then((_) async => (await _ready.future).invokeMethod<T>(method, value));
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Object?> _event(MethodCall call) async {
    if (call.method == 'ready') {
      // Native creation can finish after AppKitView has left the tree, in which case Flutter
      // skips onPlatformViewCreated. This handshake still completes the final draft read.
      if (!_ready.isCompleted) _ready.complete(_channel);
      if (_latestStyle != null) await _channel.invokeMethod<void>('style', _latestStyle);
      return null;
    }
    if (_disposed) return null;
    switch (call.method) {
      case 'height':
        _height.value = (call.arguments as num).toDouble();
      case 'changed':
        _empty = call.arguments as bool;
        handlers?.onChanged();
      case 'focus':
        handlers?.onFocus(call.arguments as bool);
      case 'enter':
        handlers?.onEnter();
      case 'escape':
        handlers?.onEscape();
      case 'paste':
        handlers?.onPaste();
      case 'arrow':
        return handlers?.onArrow(call.arguments as bool) ?? false;
      case 'toggleFocus':
        onToggleFocus();
      case 'shortcut':
        onShortcut?.call(call.arguments as String);
    }
    return null;
  }

  Map<String, Object?>? _latestStyle;

  /// Type-to-compose must wait until NSTextView, rather than an unmounted placeholder, has focus.
  Future<void> get readyForInput => _focusRequest;
  @override
  Widget view(BuildContext context, {required EditorStyle style, required String hint, required double maxHeight}) {
    return _NativeSurface(editor: this, style: style, hint: hint, maxHeight: maxHeight);
  }

  Map<String, Object?> _style(EditorStyle style, String hint, double maxHeight) => {
    'editorId': _id,
    'font': style.text.fontFamily,
    'fallback': style.text.fontFamilyFallback ?? <String>[],
    'size': style.text.fontSize ?? 15,
    'lineHeight': (style.text.fontSize ?? 15) * (style.text.height ?? 22 / 15),
    'color': style.color.toARGB32(),
    'hintColor': style.hintColor.toARGB32(),
    'cursor': style.cursor.toARGB32(),
    'hint': hint,
    'maxHeight': maxHeight.isFinite ? math.max(48, maxHeight) : 300.0,
  };

  @override
  void focus() {
    _wantFocus = true;
    _focusRequest = _ready.future.then((c) async {
      if (_wantFocus && _surfaceMounted && !_disposed) await c.invokeMethod<void>('focus');
    });
  }

  @override
  void unfocus() {
    _wantFocus = false;
    if (_ready.isCompleted) unawaited(_ready.future.then((c) => c.invokeMethod<void>('unfocus')));
  }

  @override
  void setText(String text) {
    _empty = text.isEmpty;
    unawaited(_text<void>('set', text));
  }

  @override
  void insert(String text) {
    if (text.isNotEmpty) _empty = false;
    unawaited(_text<void>('insert', text));
  }

  @override
  bool get isEmpty => _empty;
  @override
  Future<String> read() async => (await _text<String>('read'))!;
  @override
  Future<String> take() async => (await _text<String>('take'))!;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(
      _tail.then((_) async {
        final channel = await _ready.future;
        await channel.invokeMethod<void>('dispose');
        channel.setMethodCallHandler(null);
        _height.dispose();
      }),
    );
  }
}

class _NativeSurface extends StatefulWidget {
  const _NativeSurface({required this.editor, required this.style, required this.hint, required this.maxHeight});
  final NativeEditor editor;
  final EditorStyle style;
  final String hint;
  final double maxHeight;

  @override
  State<_NativeSurface> createState() => _NativeSurfaceState();
}

class _NativeSurfaceState extends State<_NativeSurface> {
  @override
  void initState() {
    super.initState();
    widget.editor._surfaceMounted = true;
  }

  @override
  void dispose() {
    widget.editor._surfaceMounted = false;
    widget.editor.unfocus();
    super.dispose();
  }

  @override
  void didUpdateWidget(_NativeSurface old) {
    super.didUpdateWidget(old);
    _updateStyle();
  }

  void _updateStyle() {
    final ed = widget.editor;
    final style = ed._style(widget.style, widget.hint, widget.maxHeight);
    if (_sameStyle(style, ed._latestStyle)) return;
    ed._latestStyle = style;
    if (ed._ready.isCompleted) {
      unawaited(ed._ready.future.then((c) => c.invokeMethod<void>('style', ed._latestStyle)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ed = widget.editor;
    ed._latestStyle = ed._style(widget.style, widget.hint, widget.maxHeight);
    return ValueListenableBuilder<double>(
      valueListenable: ed._height,
      builder: (context, height, child) => SizedBox(height: math.min(height, widget.maxHeight), child: child),
      child: AppKitView(
        viewType: 'rapp/composer',
        creationParams: ed._latestStyle,
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }
}

bool _sameStyle(Map<String, Object?> a, Map<String, Object?>? b) =>
    b != null && a.length == b.length && a.entries.every((e) {
      final o = b[e.key];
      return e.value is List && o is List ? listEquals(e.value as List, o) : e.value == o;
    });
