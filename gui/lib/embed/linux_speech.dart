// Local-only speech transport. The GUI owns the worker and accepts only the current run's events.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../paths.dart';

const linuxSpeechModelBytes = 147951465;
const linuxSpeechModelSha256 =
    '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe';

/// A verified model in the user's cache, separate from the git-backed rApp data directory.
class LinuxSpeechModel {
  LinuxSpeechModel({
    File? file,
    Uri? source,
    this.bytes = linuxSpeechModelBytes,
    this.digest = linuxSpeechModelSha256,
    HttpClient Function()? client,
  }) : file =
           file ??
           File(
             '${Platform.environment['XDG_CACHE_HOME'] ?? '${Platform.environment['HOME']}/.cache'}/rapp/speech/ggml-base.bin',
           ),
       source =
           source ??
           Uri.parse(
             'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin',
           ),
       _client = client ?? HttpClient.new;

  final File file;
  final Uri source;
  final int bytes;
  final String digest;
  final HttpClient Function() _client;
  Future<void>? _download;
  HttpClient? _activeClient;
  bool _valid = false, _failed = false, _disposed = false;
  int received = 0;

  Future<bool> _matches(File candidate) async =>
      await candidate.exists() &&
      await candidate.length() == bytes &&
      (await sha256.bind(candidate.openRead()).first).toString() == digest;

  Future<String> readiness() async {
    if (_disposed) return 'cancelled';
    if (_valid && await file.exists()) return 'ok';
    if (_download != null) return 'preparing';
    if (await _matches(file)) {
      _valid = true;
      return 'ok';
    }
    if (_disposed) return 'cancelled';
    if (_failed) {
      _failed = false;
      return 'unavailable';
    }
    _download = _fetch().whenComplete(() => _download = null);
    return 'preparing';
  }

  /// Exposed for setup/tests that need to wait for a requested download, without opening a microphone.
  Future<void> get pending => _download ?? Future<void>.value();

  Future<void> _fetch() async {
    final client = _activeClient = _client();
    client.connectionTimeout = const Duration(seconds: 20);
    // A private staging directory prevents multiple app instances sharing a partial file.
    Directory? stage;
    IOSink? sink;
    try {
      await file.parent.create(recursive: true);
      stage = await file.parent.createTemp('.download-');
      final part = File('${stage.path}/model');
      final request = await client.getUrl(source);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        throw const HttpException('Model download failed');
      }
      sink = part.openWrite();
      unawaited(sink.done.catchError((Object _) {}));
      received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        received += chunk.length;
        if (_disposed || received > bytes) {
          throw const HttpException('Invalid model download');
        }
        sink.add(chunk);
      }
      await sink.close();
      sink = null;
      final matches = await _matches(part);
      if (_disposed || !matches) {
        throw const HttpException('Model checksum mismatch');
      }
      await part.rename(file.path);
      _valid = true;
    } catch (_) {
      if (!_disposed) _failed = true;
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        // The write error was already reported as a failed preparation.
      }
      client.close(force: true);
      if (identical(_activeClient, client)) _activeClient = null;
      try {
        if (stage != null && await stage.exists()) {
          await stage.delete(recursive: true);
        }
      } on FileSystemException {
        // A removed or unavailable cache must not crash an exiting GUI.
      }
    }
  }

  void dispose() {
    _disposed = true;
    _activeClient?.close(force: true);
  }
}

/// Adapts a local worker to the existing native speech channel's contract.
class LinuxSpeechChannel extends MethodChannel
    with WidgetsBindingObserver, WindowListener {
  /// Long recordings may need the full recognition budget after capture stops.
  static const finalResultWait = Duration(minutes: 5);

  LinuxSpeechChannel({
    String? executable,
    LinuxSpeechModel? model,
    String Function()? language,
    Future<bool> Function()? isFocused,
    Future<Process> Function(String, List<String>)? spawn,
    this.startWait = const Duration(seconds: 30),
    this.finishWait = finalResultWait,
  }) : executable =
           executable ??
           '${binDir(Platform.environment, Platform.resolvedExecutable)}/rapp-speech',
       model = model ?? LinuxSpeechModel(),
       language =
           language ?? (() => PlatformDispatcher.instance.locale.languageCode),
       isFocused = isFocused ?? windowManager.isFocused,
       _spawn = spawn ?? ((exe, args) => Process.start(exe, args)),
       super('rapp/linux-speech');

  final String executable;
  final LinuxSpeechModel model;
  final String Function() language;
  final Future<bool> Function() isFocused;
  final Future<Process> Function(String, List<String>) _spawn;
  final Duration startWait, finishWait;
  Future<dynamic> Function(MethodCall)? _handler;
  Process? _process;
  Completer<String>? _ready;
  Timer? _finishTimer;
  int _epoch = 0;
  bool _disposed = false, _final = false;
  bool _observing = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _interrupt();
  }

  @override
  void onWindowBlur() => _interrupt();

  void _interrupt() {
    if (_process == null && _ready == null) return;
    unawaited(_cancel());
    _event(_epoch, 'error', {'code': 'interrupted'});
  }

  @override
  void setMethodCallHandler(Future<dynamic> Function(MethodCall)? handler) {
    _handler = handler;
    if (handler == null) {
      _disposed = true;
      if (_observing) {
        WidgetsBinding.instance.removeObserver(this);
        windowManager.removeListener(this);
      }
      model.dispose();
      unawaited(_cancel());
    }
  }

  void _event(int epoch, String name, Map<String, Object?> args) {
    // A ready completion must reach VoiceInput.start before the following event.
    Timer.run(() {
      if (!_disposed && epoch == _epoch) {
        unawaited(_handler?.call(MethodCall(name, args)));
      }
    });
  }

  void _line(int epoch, String line) {
    if (_disposed || epoch != _epoch) return;
    try {
      if (line.length > 256 * 1024) throw const FormatException();
      final data = jsonDecode(line) as Map<String, dynamic>;
      switch (data['event']) {
        case 'ready':
          if (!(_ready?.isCompleted ?? true)) _ready!.complete('ok');
        case 'partial':
        case 'final':
          if (data['text'] is! String) throw const FormatException();
          if (data['event'] == 'final') {
            _final = true;
            _finishTimer?.cancel();
          }
          _event(epoch, data['event'] as String, {
            'text': data['text'] as String,
          });
        case 'level':
          if (data['value'] is num) {
            _event(epoch, 'level', {'value': data['value']});
          }
        case 'error':
          if (!(_ready?.isCompleted ?? true)) _ready!.complete('unavailable');
          _event(epoch, 'error', {'code': data['code'] ?? 'unavailable'});
      }
    } catch (_) {
      _event(epoch, 'error', {'code': 'unavailable'});
      _process?.kill();
    }
  }

  Future<String> _start() async {
    if (_disposed || _process != null || _ready != null) return 'unavailable';
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      windowManager.addListener(this);
      _observing = true;
    }
    final epoch = ++_epoch;
    final ready = _ready = Completer<String>();
    try {
      // A delayed hold timer can fire after the main window has lost focus.
      if (!await isFocused()) return 'cancelled';
      if (epoch != _epoch || _disposed) return 'cancelled';
      final status = await model.readiness();
      if (epoch != _epoch || _disposed) return 'cancelled';
      if (status != 'ok') return status;
      final process = await _spawn(executable, const []);
      if (epoch != _epoch || _disposed) {
        process.kill();
        return 'cancelled';
      }
      _process = process;
      _final = false;
      final outputDone = Completer<void>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) => _line(epoch, line),
            onError: (Object _) {
              _event(epoch, 'error', {'code': 'unavailable'});
              process.kill();
            },
            onDone: () => outputDone.complete(),
          );
      unawaited(process.stderr.drain<void>());
      unawaited(process.stdin.done.catchError((Object _) {}));
      unawaited(
        process.exitCode.then((_) async {
          await outputDone.future;
          if (epoch != _epoch) return;
          _process = null;
          _finishTimer?.cancel();
          if (!ready.isCompleted) ready.complete('unavailable');
          if (!_final) _event(epoch, 'error', {'code': 'unavailable'});
        }),
      );
      process.stdin.writeln(
        jsonEncode({'model': model.file.path, 'language': language()}),
      );
      return await ready.future.timeout(
        startWait,
        onTimeout: () {
          process.kill();
          return 'unavailable';
        },
      );
    } on ProcessException {
      return 'unavailable';
    } on FileSystemException {
      return 'unavailable';
    } on PlatformException {
      return 'unavailable';
    } on MissingPluginException {
      return 'unavailable';
    } finally {
      if (identical(_ready, ready)) _ready = null;
    }
  }

  Future<void> _cancel() async {
    ++_epoch;
    _finishTimer?.cancel();
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) ready.complete('cancelled');
    final process = _process;
    _process = null;
    if (process != null) {
      // The recorder has a parent-death signal; no microphone process survives.
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
    }
  }

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    switch (method) {
      case 'start':
        return await _start() as T;
      case 'stop':
        final epoch = _epoch;
        _process?.stdin.writeln('{"cmd":"stop"}');
        _finishTimer?.cancel();
        _finishTimer = Timer(finishWait, () {
          _event(epoch, 'error', {'code': 'unavailable'});
          _process?.kill();
        });
      case 'cancel':
        await _cancel();
    }
    return null;
  }
}
