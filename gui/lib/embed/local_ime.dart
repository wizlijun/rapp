// This device's own input method: the writing panel turns it to Chinese, the picture back to English
// (ImeIntent). macOS goes over the `rapp/local-ime` channel (LocalImePlugin), Linux asks fcitx5 or ibus
// on the command line, iOS's built-in Rime flips its ascii mode. Elsewhere nothing is switched.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rapp_rime/rapp_rime.dart';

abstract interface class LocalIme {
  /// Selects a Chinese input method, [preferredId] if it is there. The id actually selected; null = not switched.
  Future<String?> toChinese(String? preferredId);

  /// Selects an English (ASCII) keyboard.
  Future<void> toEnglish();

  /// The input method selected now; null when it cannot be told (or a password field holds secure input).
  Future<({String id, bool ascii})?> current();
}

/// macOS → [ChannelLocalIme], Linux → [LinuxLocalIme], everything else → [NoLocalIme]
/// (iOS: main_ios.dart passes a [RimeLocalIme]).
LocalIme localImeForPlatform() => switch (defaultTargetPlatform) {
      TargetPlatform.macOS => ChannelLocalIme(),
      TargetPlatform.linux => LinuxLocalIme(Process.run),
      _ => const NoLocalIme(),
    };

/// Nothing to switch.
class NoLocalIme implements LocalIme {
  const NoLocalIme();

  @override
  Future<String?> toChinese(String? preferredId) async => null;

  @override
  Future<void> toEnglish() async {}

  @override
  Future<({String id, bool ascii})?> current() async => null;
}

/// macOS: the native side picks the input source (TIS).
class ChannelLocalIme implements LocalIme {
  ChannelLocalIme([this.channel = const MethodChannel('rapp/local-ime')]);

  final MethodChannel channel;

  @override
  Future<String?> toChinese(String? preferredId) =>
      channel.invokeMethod<String>('toChinese', {'preferred': preferredId});

  @override
  Future<void> toEnglish() => channel.invokeMethod<void>('toEnglish');

  @override
  Future<({String id, bool ascii})?> current() async {
    final m = await channel.invokeMapMethod<String, Object?>('current');
    final id = m?['id'], ascii = m?['ascii'];
    return id is String && ascii is bool ? (id: id, ascii: ascii) : null;
  }
}

/// Runs a command; [Process.run] in the app, a fake in tests.
typedef RunCommand = Future<ProcessResult> Function(String exe, List<String> args);

/// Linux: fcitx5 (`fcitx5-remote`) when it runs, else ibus (`ibus engine`). Neither, or a command missing:
/// nothing is switched and [current] is null.
class LinuxLocalIme implements LocalIme {
  LinuxLocalIme(this.run);

  final RunCommand run;

  static const _usEngine = 'xkb:us::eng';

  /// `fcitx5-remote` exits 0 and says 1 (inactive) or 2 (active); anything else is not a running fcitx5.
  Future<String?> _fcitx() async {
    final r = await _run('fcitx5-remote', const []);
    if (r == null || r.exitCode != 0) return null;
    final out = '${r.stdout}'.trim();
    return out == '1' || out == '2' ? out : null;
  }

  /// The ibus engine selected now, or null when ibus does not answer.
  Future<String?> _ibus() async {
    final r = await _run('ibus', const ['engine']);
    if (r == null || r.exitCode != 0) return null;
    final out = '${r.stdout}'.trim();
    return out.isEmpty ? null : out;
  }

  Future<ProcessResult?> _run(String exe, List<String> args) async {
    try {
      return await run(exe, args);
    } on ProcessException {
      return null;
    }
  }

  @override
  Future<({String id, bool ascii})?> current() async {
    final f = await _fcitx();
    if (f != null) return (id: 'fcitx5', ascii: f != '2');
    final e = await _ibus();
    if (e != null) return (id: 'ibus:$e', ascii: e.startsWith('xkb:'));
    return null;
  }

  @override
  Future<String?> toChinese(String? preferredId) async {
    if (await _fcitx() != null) {
      await _run('fcitx5-remote', const ['-o']);
      return 'fcitx5';
    }
    if (await _ibus() == null) return null;
    // ibus has no "the Chinese one": only an engine seen before (saved as `ibus:<engine>`) is set.
    if (preferredId == null || !preferredId.startsWith('ibus:')) return null;
    final engine = preferredId.substring('ibus:'.length);
    if (engine.isEmpty) return null;
    final r = await _run('ibus', ['engine', engine]);
    return r != null && r.exitCode == 0 ? preferredId : null;
  }

  @override
  Future<void> toEnglish() async {
    if (await _fcitx() != null) {
      await _run('fcitx5-remote', const ['-c']);
    } else if (await _ibus() != null) {
      await _run('ibus', const ['engine', _usEngine]);
    }
  }
}

/// iOS: the built-in Rime leaves its ascii mode for Chinese. English is left to the picture side
/// (keys typed on the picture never go through Rime), and Rime does not say what it is.
class RimeLocalIme implements LocalIme {
  RimeLocalIme(this.rime);

  final RimeLink rime;

  @override
  Future<String?> toChinese(String? preferredId) async {
    await rime.setAscii(false);
    return 'rime';
  }

  @override
  Future<void> toEnglish() async {}

  @override
  Future<({String id, bool ascii})?> current() async => null;
}
