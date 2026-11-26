// Session labels (spec 2026-11-26-rapp-session-labels-design.md): the title and note the user gave a session, kept by
// the device that runs it (its service's labels.json) and the same on every client.

/// One session's label; either part may be empty (never both: that is no label).
class SessionLabel {
  const SessionLabel({this.title = '', this.note = ''});
  final String title, note;

  static SessionLabel? fromJson(Object? m) {
    if (m is! Map) return null;
    final l = SessionLabel(
      title: m['title'] is String ? m['title'] as String : '',
      note: m['note'] is String ? m['note'] as String : '',
    );
    return l.title.isEmpty && l.note.isEmpty ? null : l;
  }

  @override
  bool operator ==(Object other) => other is SessionLabel && other.title == title && other.note == note;
  @override
  int get hashCode => Object.hash(title, note);
}

/// A device's whole table, as its watch last pushed it.
class LabelTable {
  const LabelTable(this.rev, this.labels);
  final int rev;

  /// app (a bundle id or a terminal id) → its label.
  final Map<String, SessionLabel> labels;

  static LabelTable fromJson(Map<String, dynamic> m) {
    final raw = m['labels'];
    return LabelTable(m['rev'] is int ? m['rev'] as int : 0, {
      if (raw is Map)
        for (final e in raw.entries) '${e.key}': ?SessionLabel.fromJson(e.value),
    });
  }
}

const labelTitleMax = 64;
const labelNoteMax = 200;

/// The title as the device keeps it, or why it would refuse it (the same rule as the service's).
({String? value, String? error}) cleanLabelTitle(String s) {
  final t = s.trim();
  if (t.runes.any(_control)) return (value: null, error: '标题只能是一行');
  if (t.runes.length > labelTitleMax) return (value: null, error: '标题最多 $labelTitleMax 个字');
  return (value: t, error: null);
}

/// The note as the device keeps it (line breaks become spaces), or why it would refuse it.
({String? value, String? error}) cleanLabelNote(String s) {
  final t = s.replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();
  if (t.runes.any(_control)) return (value: null, error: '备注里有不能显示的字符');
  if (t.runes.length > labelNoteMax) return (value: null, error: '备注最多 $labelNoteMax 个字');
  return (value: t, error: null);
}

bool _control(int r) => r < 0x20 || (r >= 0x7f && r < 0xa0);
