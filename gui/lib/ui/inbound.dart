// 正在被接入: the sessions other devices hold on this machine, as the overview's 本机 column lists them.
// They are not tasks: nothing opens on a tap; each one can only be cut off (断开).
import '../hub_client.dart';
import '../service_client.dart';
import '../term/term_id.dart';

/// The card's first line: a text terminal as it is titled everywhere else, an app by its id.
String inboundTitle(String app) {
  final t = parseTermId(app);
  return t == null ? app : termTitle(termDisplayName(t.name, t.host));
}

/// Who is in: a saved device's name (matched by id, as relayed sessions carry it), then the name the peer
/// declared, then the peer as the service saw it.
String inboundWho(ServiceSession s, List<HubHost> hosts) {
  for (final h in hosts) {
    if (h.id == s.peer && h.name.isNotEmpty) return h.name;
  }
  final declared = s.name;
  return declared != null && declared.isNotEmpty ? declared : s.peer;
}

/// How long since [since] (Unix seconds), rounded down; unknown or in the future reads 0 秒.
String inboundAge(Object? since, DateTime now) {
  final secs = since is num ? now.millisecondsSinceEpoch ~/ 1000 - since.toInt() : 0;
  final d = secs < 0 ? 0 : secs;
  if (d < 60) return '$d 秒';
  if (d < 3600) return '${d ~/ 60} 分钟';
  return '${d ~/ 3600} 小时';
}

/// The card's second line.
String inboundSubtitle(ServiceSession s, List<HubHost> hosts, DateTime now) =>
    '${inboundWho(s, hosts)} · ${inboundAge(s.since, now)}${s.side ? ' · 传文件' : ''}';
