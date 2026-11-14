// The `term:` id: `term:<backend>[@<host>]:<name>`. The only place in the GUI that parses it.

bool isTermApp(String app) => app.startsWith('term:');

({String backend, String? host, String name})? parseTermId(String id) {
  if (!id.startsWith('term:')) return null;
  final rest = id.substring(5);
  final i = rest.indexOf(':');
  if (i < 0) return null;
  final head = rest.substring(0, i);
  final name = rest.substring(i + 1);
  if (name.isEmpty) return null;
  final at = head.indexOf('@');
  final backend = at < 0 ? head : head.substring(0, at);
  final host = at < 0 ? null : head.substring(at + 1);
  if (backend.isEmpty || !RegExp(r'^[a-z0-9]+$').hasMatch(backend)) return null;
  if (host != null && !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(host)) return null;
  return (backend: backend, host: host, name: name);
}

String termDisplayName(String name, String? host) => host == null ? name : '$name @$host';
