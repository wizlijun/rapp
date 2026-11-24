// A device's shared ports: what the service says about them (this device or another one).
import 'service_client.dart';

class Device {
  const Device({required this.fp, required this.name});
  final String fp;
  final String name;

  static Device fromJson(Map<String, dynamic> m) => Device(fp: '${m['fp'] ?? ''}', name: '${m['name'] ?? ''}');
}

/// Why a share number changed: it collided with `with_`'s share at number `from`. Kept so the
/// row can say so until the user acknowledges it.
class Renumbered {
  const Renumbered({required this.from, required this.with_});
  final int from;
  final String with_;
}

class ShareRow {
  const ShareRow({
    required this.port,
    required this.note,
    required this.allow,
    required this.addr,
    required this.web,
    required this.listening,
    required this.mine,
    this.proto = 'http',
    this.protoAuto = false,
    this.local,
    this.wanted,
    this.taken = false,
    this.renumbered,
  });
  final int port;
  final String note;
  final List<Device> allow;

  /// What to type or open on this computer to reach it, exactly as the service says it:
  /// `http://localhost:28000` or `ssh -p 28001 localhost`. The port is a local one the service
  /// listens on and carries to the device. Empty when this computer has no way to the share.
  final String addr;
  final bool web;
  final bool listening;

  /// This computer may use the share: its allow list is empty or names this device.
  final bool mine;

  /// `http`, `https`, `tcp` or `ssh`; [protoAuto] when the service guessed it from the port.
  final String proto;
  final bool protoAuto;

  /// The local number this share uses on this computer, and the one a visitor wanted but
  /// yielded (set only when they differ), so the row can say why the address looks odd.
  final int? local, wanted;

  /// The sharer's own number is held by another program here.
  final bool taken;
  final Renumbered? renumbered;

  static ShareRow fromJson(Map<String, dynamic> m) => ShareRow(
        port: (m['port'] as num).toInt(),
        note: '${m['note'] ?? ''}',
        allow: _devices(m['allow']),
        addr: '${m['addr'] ?? ''}',
        web: m['web'] == true,
        listening: m['listening'] == true,
        mine: m['mine'] == true,
        proto: m['proto'] is String ? m['proto'] as String : 'http',
        protoAuto: m['proto_auto'] == true,
        local: (m['local'] as num?)?.toInt(),
        wanted: (m['wanted'] as num?)?.toInt(),
        taken: m['taken'] == true,
        renumbered: m['renumbered'] is Map
            ? Renumbered(from: ((m['renumbered'] as Map)['from'] as num).toInt(), with_: '${(m['renumbered'] as Map)['with'] ?? ''}')
            : null,
      );
}

List<Device> _devices(Object? v) => (v as List? ?? const []).whereType<Map<String, dynamic>>().map(Device.fromJson).toList();

class ShareTable {
  const ShareTable({required this.id, required this.me, required this.rows, required this.known, this.old = false});
  final String id;
  final String me;
  final List<ShareRow> rows;
  final List<Device> known;

  /// The other device is an older version: it would ignore a protocol, so none is offered.
  final bool old;

  static ShareTable fromJson(Map<String, dynamic> m) => ShareTable(
        id: '${m['id'] ?? ''}',
        me: '${m['me'] ?? ''}',
        rows: (m['shares'] as List? ?? const []).whereType<Map<String, dynamic>>().map(ShareRow.fromJson).toList(),
        known: _devices(m['known']),
        old: m['old'] == true,
      );
}

class Shared {
  const Shared({required this.port, this.warn});
  final int port;
  final String? warn;
}

abstract class SharesApi {
  /// [to] null is this device.
  Future<ShareTable> shares({String? to});
  Future<List<Shared>> share({String? to, required List<int> ports, String? note, List<String>? allow, String? proto});
  Future<bool> unshare({String? to, required int port});
}

String shareErrorText(Object e) {
  final s = e is ServiceException ? e.message : '$e';
  switch (s) {
    case 'offline' || 'no key' || 'unknown name':
      return '离线，读不到它的端口';
    case 'old version':
      return '对方的 rApp 还不支持分享端口';
    case 'policy':
      return '对方的策略不允许远程设置';
    case 'limit':
      return '最多分享 64 个端口';
    case 'bad port':
      return '端口号是 1 到 65535 的数字';
    case 'service not running' || 'service connection closed':
      return '本机的 rApp 服务没有在运行';
  }
  return '出错了：$s';
}

/// The error leaves nothing to type into: offline, old version, policy, no local service.
bool shareErrorHidesInput(Object e) {
  final s = e is ServiceException ? e.message : '$e';
  return const {'offline', 'no key', 'unknown name', 'old version', 'policy', 'service not running', 'service connection closed'}
      .contains(s);
}

final _digits = RegExp(r'^[0-9]+$');

/// 1 to 65535 in ASCII digits, spaces around allowed.
int? parsePort(String s) {
  final t = s.trim();
  if (!_digits.hasMatch(t) || t.length > 5) return null;
  final n = int.parse(t);
  return n >= 1 && n <= 65535 ? n : null;
}
