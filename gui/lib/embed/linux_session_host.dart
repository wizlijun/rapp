import 'dart:io';

import 'package:flutter/services.dart';

import '../paths.dart';
import 'session_copy.dart';
import 'session_host.dart';

class LinuxSessionHost implements SessionHost {
  LinuxSessionHost({
    this.channel = const MethodChannel('rapp/linux'),
    Map<String, String>? env,
  }) : env = env ?? Platform.environment;
  final MethodChannel channel;
  final Map<String, String> env;
  bool _native = false;

  @override
  Future<void> init(
    Future<Object?> Function(MethodCall call) onDetachCall,
  ) async {
    try {
      _native = await channel.invokeMethod<bool>('init') ?? false;
      channel.setMethodCallHandler(onDetachCall);
    } on MissingPluginException {
      _native = false;
    }
  }

  @override
  bool get supportsDetach => _native;
  @override
  bool get supportsInlineNativeComposer => true;
  @override
  MethodChannel? get detachChannel => channel;

  @override
  String? get traceDir {
    final d = env['RAPP_STREAM_TRACE_DIR'];
    return d == null || d.isEmpty ? null : d;
  }

  @override
  String downloads() =>
      env['RAPP_DOWNLOADS'] ??
      '${dataRoot(env, Platform.operatingSystem)}/files/transfers';

  @override
  Future<bool> reveal(String path) async {
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

  @override
  Future<SessionCopy?> readClipboard() async {
    try {
      return SessionCopy.fromMap(
        await channel.invokeMethod<Object?>('clipboard_read'),
      );
    } on MissingPluginException {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      return text == null
          ? null
          : SessionCopy('text', text: text, uti: 'public.utf8-plain-text');
    }
  }

  @override
  Future<bool> writeClipboard(SessionCopy copy) async {
    if (copy.kind == 'text') {
      await Clipboard.setData(ClipboardData(text: copy.text!));
      return true;
    }
    if (copy.kind == 'files') {
      for (final path in copy.files) {
        if (!await File(path).exists()) return false;
      }
    }
    return await channel.invokeMethod<bool>('clipboard_write', copy.toMap()) ??
        false;
  }

  @override
  Future<List<String>> chooseFiles() async => List<String>.from(
    await channel.invokeMethod<List<Object?>>('choose_files') ?? [],
  );
}
