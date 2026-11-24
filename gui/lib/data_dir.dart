// Creates the data root layout and copies the old config into it (spec §1-§2); mirrors rust/net/src/datadir.rs.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const dataReadme = r'''# rapp 数据目录

rApp 的所有数据都在这个目录里。

## 子目录

- `shared/`：所有设备共用，放 app 配置 `apps.json` 和项目、常用 `workspace.json`。进 git。
- `devices/<设备id>/`：每台设备一份，只由这台设备写，放 `device.json`（这台是什么）和 `gui.json`（界面偏好）。进 git。
  `inputs/` 里是写作面板发出去的话，一天一个 `YYYY-MM-DD.jsonl`，一行一条记录（格式见规格《输入记录》）：`v, id, ts, kind, from, host, app, session, run, window, projects, text, blocks, result, after, source`，只在末尾加行。里面是你的原话，可能有私事，和钉住的剪贴板同样对待。
- `agent/`：agent 的上下文。rApp 只建目录和 `agent/README.md`，里面的内容归你和 agent。进 git。
- `clipboard/`：钉住的文字条目，一条一个 `<时间>-<短标题>.md`。进 git。
- `files/`：二进制，不进 git。`files/transfers/` 是收发的文件，`files/clipboard/` 是钉住的图片和文件。
- `local/`：本机私有，不进 git。口令、密钥、`service.json`、`hosts.json` 等机密只在这里。
  `local/drafts/` 是没发出去的草稿，每个会话一个文件，不进 git。

## git

- 进 git 的：`shared/`、`devices/`、`agent/`、`clipboard/`、本文件和 `.gitignore`。
- 不进 git 的：`files/` 和 `local/`。机密只在 `local/`，不会进 git。
- 要同步文字，自己执行 `git remote add origin <地址>`。rApp 每分钟提交一次，有 remote 就推和拉。
- 第二台设备：先 `git clone <地址> ~/rapp`，再启动 rApp。
- 取消固定只删文件，git 历史里还在。

## 同步二进制

`files/` 里的二进制可以用 Syncthing、iCloud 云盘、坚果云等文件夹同步工具，把它们指向 `files` 这个文件夹。

## 其他

- 日志：macOS 在 `~/Library/Logs/rapp`；Linux 在 `$XDG_STATE_HOME/rapp`（默认 `~/.local/state/rapp`）。设置 `RAPP_HOME` 时在 `$RAPP_HOME/local/logs`，`RAPP_LOG_DIR` 可单独指定。
- 这个目录的位置可以在 rApp 设置页的「数据目录」里改。
''';

const agentReadme = r'''# agent 上下文

这里放 agent 的上下文，内容归用户和 agent，rApp 不动。
改 rApp 的配置前，先读 rApp 仓库里的《配置规范总览》：`docs/superpowers/specs/2026-11-13-rapp-config-reference.md`。
''';

const dataGitignore = r'''# rApp 写的。只有下面放行的进 git（数据目录规格 D2、D3）
/*
!/.gitignore
!/README.md
!/shared/
!/devices/
!/agent/
!/clipboard/
files/
local/
*.tmp
*.bad
''';

/// First line of `README.md`; how other code recognises a rApp data dir.
const readmeMarker = '# rapp 数据目录';
const migratedFrom = 'migrated-from';

/// Makes the layout, writes the texts that are missing, and copies the old config in once.
/// Returns whether this call migrated. Copies only; [legacy] is never changed. No [legacy] (iOS): nothing to copy.
/// Throws [FileSystemException] on failure.
bool prepareDataDir(String root, String? legacy) {
  for (final d in ['shared', 'devices', 'agent', 'clipboard', 'files/transfers', 'files/clipboard']) {
    Directory('$root/$d').createSync(recursive: true);
  }
  final loc = '$root/local';
  Directory(loc).createSync(recursive: true);
  _chmod('700', loc);
  for (final (path, text) in [
    ('$root/README.md', dataReadme),
    ('$root/.gitignore', dataGitignore),
    ('$root/agent/README.md', agentReadme),
  ]) {
    final f = File(path);
    if (!f.existsSync()) f.writeAsStringSync(text);
  }
  // Client-only Linux installs may never have started rapp-service. Preserve
  // their saved hosts, projects and preferences even without a service.json.
  final currentId = _serviceId('$loc/service.json');
  if (currentId != null) _copyIfMissing('$loc/gui.json', '$root/devices/$currentId/gui.json');
  if (legacy == null || File('$loc/$migratedFrom').existsSync()) return false;
  final table = <(String, String)>[
    ('hosts.json', '$loc/hosts.json'),
    ('update.json', '$loc/update.json'),
    ('update-applied.json', '$loc/update-applied.json'),
    ('permission-guide-shown', '$loc/permission-guide-shown'),
    ('workspace.json', '$root/shared/workspace.json'),
    ('apps.json', '$root/shared/apps.json'),
  ];
  final id = currentId ?? _serviceId('$legacy/service.json');
  table.add(('gui.json', id == null ? '$loc/gui.json' : '$root/devices/$id/gui.json'));
  table.add(('service.json', '$loc/service.json'));
  if (!table.any((e) => File('$legacy/${e.$1}').existsSync())) return false;
  for (final (old, nu) in table) {
    _copyIfMissing('$legacy/$old', nu);
  }
  writePrivate('$loc/$migratedFrom', utf8.encode('$legacy\n'));
  return true;
}

/// Adopt (D12): copies each file of `from/local/` that `to/local/` lacks. That data is this device's own and
/// never synced. `service.json` goes last. Never overwrites; [from] is not changed.
void copyLocalIfMissing(String from, String to) {
  final src = '$from/local', dst = '$to/local';
  Directory(dst).createSync(recursive: true);
  _chmod('700', dst);
  if (!Directory(src).existsSync()) return;
  final rel =
      Directory(src)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .map((f) => f.path.substring(src.length + 1))
          .where((r) => r != 'service.json')
          .toList()
        ..sort();
  for (final r in [...rel, 'service.json']) {
    _copyIfMissing('$src/$r', '$dst/$r');
  }
}

/// True when `dir/README.md` starts with [readmeMarker].
bool isRappDataDir(String dir) {
  try {
    final text = File('$dir/README.md').readAsStringSync();
    return text.split('\n').first.trimRight() == readmeMarker;
  } catch (_) {
    return false;
  }
}

/// This device's id when no rapp-service picks one (iOS): `local/service.json`'s `id`, made on the first
/// start (9 digits, like `rapp_net::crypto::random_id`) with the file's other fields kept, plus
/// `devices/<id>/device.json`. Input records and `gui.json` need it. An empty [name] keeps the one
/// written before. Throws when `service.json` cannot be read as JSON (it holds the relay and key: never
/// overwritten then) or a write fails.
String ensureDeviceId(String root, {required String name, required String os}) {
  final path = '$root/local/service.json';
  final f = File(path);
  final Map<String, Object?> svc;
  if (f.existsSync()) {
    final v = jsonDecode(f.readAsStringSync());
    if (v is! Map<String, Object?>) throw FormatException('service.json is not an object', path);
    svc = v;
  } else {
    svc = {};
  }
  var id = svc['id'];
  if (id is! String || !RegExp(r'^[1-9][0-9]{8}$').hasMatch(id)) {
    id = '${100000000 + Random.secure().nextInt(900000000)}';
    svc['id'] = id;
    writePrivate(path, utf8.encode(jsonEncode(svc)));
  }
  final dev = '$root/devices/$id/device.json';
  var n = name;
  if (n.isEmpty) {
    try {
      final old = jsonDecode(File(dev).readAsStringSync());
      if (old is Map && old['name'] is String) n = old['name'] as String;
    } catch (_) {}
  }
  final bytes = utf8.encode('${const JsonEncoder.withIndent('  ').convert({'id': id, 'name': n, 'os': os})}\n');
  final d = File(dev);
  if (!d.existsSync() || !_same(d.readAsBytesSync(), bytes)) writePrivate(dev, bytes);
  return id;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String? _serviceId(String path) {
  try {
    final v = jsonDecode(File(path).readAsStringSync());
    final id = v is Map ? v['id'] : null;
    if (id is String && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) return id;
  } catch (_) {}
  return null;
}

void _copyIfMissing(String from, String to) {
  if (File(to).existsSync() || !File(from).existsSync()) return;
  writePrivate(to, File(from).readAsBytesSync());
}

/// Writes [data] with mode 0600 via a temp file and a rename.
void writePrivate(String path, List<int> data) {
  File(path).parent.createSync(recursive: true);
  final tmp = File('$path.tmp');
  tmp.writeAsBytesSync(const []);
  _chmod('600', tmp.path);
  tmp.writeAsBytesSync(data, flush: true);
  tmp.renameSync(path);
}

void _chmod(String mode, String path) {
  // iOS starts no processes; the app sandbox keeps the data private.
  if (Platform.isWindows || Platform.isIOS) return;
  final r = Process.runSync('chmod', [mode, path]);
  if (r.exitCode != 0) throw FileSystemException('chmod $mode failed: ${r.stderr}'.trim(), path);
}
