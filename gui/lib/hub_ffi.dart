// The hub inside the app (iOS): rust/hub-ffi, statically linked, over dart:ffi. The same JSON lines as rapp-hub's
// stdin/stdout (rust/hub-ffi/include/rapp_hub.h).
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'hub_client.dart';

/// [s] without one trailing newline: the hub takes a line with or without it, and [encodeLine] adds one.
String toHubLine(String s) => s.endsWith('\n') ? s.substring(0, s.length - 1) : s;

typedef _OnLineC = Void Function(Pointer<Utf8>);
typedef _StartC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<NativeFunction<_OnLineC>>);
typedef _StartD = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<NativeFunction<_OnLineC>>);
typedef _SendC = Int32 Function(Pointer<Utf8>);
typedef _SendD = int Function(Pointer<Utf8>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeD = void Function(Pointer<Utf8>);
typedef _StopC = Void Function();
typedef _StopD = void Function();

/// The four C functions, looked up in the app binary itself.
class _Lib {
  _Lib()
      : start = _process.lookupFunction<_StartC, _StartD>('rapp_hub_start'),
        send = _process.lookupFunction<_SendC, _SendD>('rapp_hub_send'),
        free = _process.lookupFunction<_FreeC, _FreeD>('rapp_hub_free_line'),
        stop = _process.lookupFunction<_StopC, _StopD>('rapp_hub_stop');

  static final _process = DynamicLibrary.process();
  final _StartD start;
  final _SendD send;
  final _FreeD free;
  final _StopD stop;
}

/// rapp_hub_stop waits up to 2 s for the hub to end: off the UI isolate.
Future<void> _stopOffThread() =>
    Isolate.run(() => DynamicLibrary.process().lookupFunction<_StopC, _StopD>('rapp_hub_stop')());

class FfiHubTransport implements HubTransport {
  FfiHubTransport._(this._lib);

  final _Lib _lib;
  final _lines = StreamController<String>();
  late final NativeCallable<_OnLineC> _onLine;
  bool _stopping = false;

  @override
  Stream<String> get lines => _lines.stream;

  /// Starts the hub with [home] (the data root's `local/`), its log in [logDir], introducing itself as [name].
  /// Throws [HubException] when it cannot start.
  static FfiHubTransport start({required String home, required String logDir, required String name}) {
    final t = FfiHubTransport._(_Lib());
    t._onLine = NativeCallable<_OnLineC>.listener(t._line);
    final rc = using((arena) => t._lib.start(home.toNativeUtf8(allocator: arena),
        logDir.toNativeUtf8(allocator: arena), name.toNativeUtf8(allocator: arena), t._onLine.nativeFunction));
    if (rc != 0) {
      t._onLine.close();
      throw HubException(switch (rc) {
        -1 => 'hub 已经在运行',
        -2 => 'hub 的参数不对',
        _ => 'hub 起不来（$rc）',
      });
    }
    return t;
  }

  /// One line from the hub (copied, then freed); NULL is the end, after a stop or when the hub ended on its own.
  void _line(Pointer<Utf8> p) {
    if (p == nullptr) {
      _onLine.close();
      _lines.close();
      // Ended on its own: the slot stays taken (start -1, send -3) until rapp_hub_stop.
      if (!_stopping) {
        _stopping = true;
        unawaited(_stopOffThread());
      }
      return;
    }
    String? line;
    try {
      line = p.toDartString();
    } on FormatException {
      // Not UTF-8 (the hub only writes JSON): dropped, like a garbage stdout line.
    } finally {
      _lib.free(p);
    }
    if (line != null && !_lines.isClosed) _lines.add(line);
  }

  @override
  void send(String line) {
    final rc = using((arena) => _lib.send(toHubLine(line).toNativeUtf8(allocator: arena)));
    if (rc == -1 || rc == -3) throw HubException('hub 已退出');
    if (rc != 0) throw HubException('hub 不收这一行（$rc）');
  }

  /// Like closing rapp-hub's stdin: the hub closes all sessions and ends; [lines] closes on its NULL.
  @override
  Future<void> close() async {
    if (_stopping) return;
    _stopping = true;
    await _stopOffThread();
  }
}
