import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'linux_transfer.dart';

class SessionCopy {
  const SessionCopy(
    this.kind, {
    this.text,
    this.bytes,
    this.files = const [],
    this.uti = 'public.data',
  });
  final String kind, uti;
  final String? text;
  final Uint8List? bytes;
  final List<String> files;
  Map<String, Object?> toMap() => {
    'kind': kind,
    'text': text,
    'bytes': bytes,
    'files': files,
    'uti': uti,
  };
  static SessionCopy? fromMap(Object? value) {
    if (value is! Map) return null;
    final kind = value['kind'];
    if (kind == 'text' && value['text'] is String) {
      return SessionCopy(
        'text',
        text: value['text'] as String,
        uti: 'public.utf8-plain-text',
      );
    }
    if (kind == 'files' && value['files'] is List) {
      return SessionCopy(
        'files',
        files: List<String>.from(value['files'] as List),
        uti: 'public.file-url',
      );
    }
    if ((kind == 'image' || kind == 'data') && value['bytes'] is Uint8List) {
      final bytes = value['bytes'] as Uint8List;
      if (bytes.length > linuxMemoryLimit) throw StateError('这一项超过 256 MB');
      return SessionCopy(
        kind as String,
        bytes: bytes,
        uti:
            value['uti'] as String? ??
            (kind == 'image' ? 'public.png' : 'public.data'),
      );
    }
    return null;
  }
}

Future<String> saveSessionCopy(
  SessionCopy copy,
  String textDir,
  String fileDir,
  String stem,
) async {
  final dir = copy.kind == 'text' ? textDir : fileDir;
  await Directory(dir).create(recursive: true);
  final ext = switch (copy.kind) {
    'text' => '.md',
    'image' => '.png',
    'data' => '.rapp-clip',
    _ => '',
  };
  var n = 1;
  var target = '$dir/${safeTransferName(stem)}$ext';
  while (await FileSystemEntity.type(target) != FileSystemEntityType.notFound) {
    target = '$dir/${safeTransferName(stem)}-${++n}$ext';
  }
  final staging = await Directory(dir).createTemp('.pin-');
  final tmp = '${staging.path}/item';
  try {
    switch (copy.kind) {
      case 'text':
        await File(tmp).writeAsString(copy.text!, flush: true);
      case 'image':
        await File(tmp).writeAsBytes(copy.bytes!, flush: true);
      case 'data':
        await Directory(tmp).create();
        await File(
          '$tmp/clip.json',
        ).writeAsString(jsonEncode({'kind': 'data', 'uti': copy.uti}));
        await File('$tmp/data').writeAsBytes(copy.bytes!, flush: true);
      case 'files':
        await Directory(tmp).create();
        for (final path in copy.files) {
          if (await FileSystemEntity.type(path) != FileSystemEntityType.file) {
            throw StateError('文件不存在或是文件夹');
          }
          await File(
            path,
          ).copy(await unusedTransferPath(tmp, path.split('/').last));
        }
      default:
        throw StateError('不支持这一项');
    }
    if (copy.kind == 'files' || copy.kind == 'data') {
      await Directory(tmp).rename(target);
    } else {
      await File(tmp).rename(target);
    }
    return target;
  } finally {
    await staging.delete(recursive: true);
  }
}

Future<SessionCopy?> loadSessionCopy(String path) async {
  if (await Directory(path).exists()) {
    if (path.endsWith('.rapp-clip') && await File('$path/clip.json').exists()) {
      final m = jsonDecode(await File('$path/clip.json').readAsString());
      if (m is! Map ||
          m['uti'] is! String ||
          await File('$path/data').length() > linuxMemoryLimit) {
        return null;
      }
      return SessionCopy(
        'data',
        uti: m['uti'] as String,
        bytes: await File('$path/data').readAsBytes(),
      );
    }
    final files = <String>[];
    await for (final e in Directory(path).list(followLinks: false)) {
      if (e is File && !e.path.split('/').last.startsWith('.')) {
        files.add(e.path);
      }
    }
    files.sort();
    return SessionCopy('files', files: files, uti: 'public.file-url');
  }
  final file = File(path);
  if (await file.length() > linuxMemoryLimit) return null;
  if (path.endsWith('.md')) {
    return SessionCopy(
      'text',
      text: await file.readAsString(),
      uti: 'public.utf8-plain-text',
    );
  }
  return SessionCopy(
    path.endsWith('.png') ? 'image' : 'data',
    bytes: await file.readAsBytes(),
    uti: path.endsWith('.png') ? 'public.png' : 'public.data',
  );
}
