// The `term:` id: `term:<backend>[@<host>]:<name>`. The only place in the GUI that parses it.

bool isTermApp(String app) => app.startsWith('term:');

/// A text terminal: a pty session held by `rapp-term run`. Its size follows the host window and it has one window.
bool isPtyTerm(String app) => parseTermId(app)?.backend == 'pty';

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

/// The label of a text terminal in the top bar, the session list, the overview and the favourites.
String termTitle(String name) => 'CLI · $name';

String termDisplayName(String name, String? host) => host == null ? name : '$name @$host';

/// The longest name a text terminal can be renamed to, in characters (code points).
const termNameMax = 64;

/// A name a text terminal can be renamed to, the same rule as the device's `clean_name`: trimmed, not empty, no
/// control characters, at most [termNameMax] characters (Rust `chars()`, so code points, not UTF-16 units). Null
/// when the name is refused.
String? cleanTermName(String s) {
  final t = s.trim();
  if (t.isEmpty || t.runes.length > termNameMax) return null;
  // Rust `char::is_control`: Unicode category Cc (C0, DEL, C1).
  if (t.runes.any((r) => r < 0x20 || (r >= 0x7f && r <= 0x9f))) return null;
  return t;
}
