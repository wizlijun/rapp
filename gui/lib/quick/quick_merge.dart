// The pure rules that say, per synced 快捷区 doc, whether to take the center service's copy, push the local one or
// wait (quick-row spec §10.3). No I/O: the sync (QuickSync) feeds it and acts on the answer.
import 'dart:convert';
import 'dart:math';

import '../embed/phrases.dart';
import '../embed/strip_cmds.dart';
import 'key_layout.dart';
import 'quick_prefs.dart';

sealed class MergeStep {
  const MergeStep();
}

/// Take [doc] (the service's) as the local doc, `at` and all; `synced` becomes its `at`.
class Adopt extends MergeStep {
  const Adopt(this.doc);
  final QuickDoc doc;
}

/// `PUT` [doc] with [base] as the `at` the client believes the service holds; on success `synced = doc.at`.
class Push extends MergeStep {
  const Push(this.doc, this.base);
  final QuickDoc doc;
  final int base;
}

/// Nothing to do.
class Keep extends MergeStep {
  const Keep();
}

/// The three-row table of §10.3, for a doc of a service this device already knows. [local] is the doc as it is,
/// [synced] the `at` it had when it last agreed with this service (0 never), [server] the service's copy (null: none).
/// A push takes `at = max(local.at, server.at + 1)` so a clock that runs behind never hides the change. [nowMs] is
/// unused, kept for the signature. [name] is the doc's name (`phrases` `layout` `stars`): a service copy that
/// [isDocReadable] rejects counts as missing (§10.2), so a readable local doc is pushed over it.
MergeStep decide({
  required QuickDoc local,
  required int synced,
  required QuickDoc? server,
  required int nowMs,
  void Function(String)? log,
  required String name,
}) {
  if (server == null) return Push(local, 0);
  if (!isDocReadable(name, server.data) && isDocReadable(name, local.data)) {
    return Push(QuickDoc(max(local.at, server.at + 1), local.data), server.at);
  }
  final changedHere = local.at > synced;
  if (server.at <= synced) {
    return changedHere ? Push(QuickDoc(max(local.at, server.at + 1), local.data), server.at) : const Keep();
  }
  if (!changedHere) return Adopt(server);
  if (local.at > server.at) return Push(QuickDoc(max(local.at, server.at + 1), local.data), server.at);
  log?.call('both changed, the service is later: adopting its copy (local at ${local.at}, service at ${server.at})');
  return Adopt(server);
}

/// Whether this doc must go through [firstJoin] rather than [decide]: the service is another one, nothing was synced
/// yet, the service's copy is older than what was synced, or it is gone after a sync.
bool isFirstJoin({
  required String? knownStore,
  required String store,
  required int synced,
  required QuickDoc? server,
}) =>
    knownStore != store ||
    synced == 0 ||
    (server != null && server.at < synced) ||
    (synced > 0 && server == null);

/// [id] made distinct, the same way every time: a hash of [salt] appended.
String _derivedId(String id, String salt) {
  var h = 0x811c9dc5;
  for (final u in salt.codeUnits) {
    h = ((h ^ u) * 0x01000193) & 0xffffffff;
  }
  return '$id-${h.toRadixString(36)}';
}

/// Whether [data] is the shape doc [name] is stored in; anything else counts as missing (spec §10.2).
bool isDocReadable(String name, Object? data) => switch (name) {
      'layout' => data is Map && data['rows'] is List,
      _ => data is List,
    };

/// The first meeting with a service, for the three shared docs at once (they depend on each other: stars follow the
/// ids phrases were matched under). Missing docs in [local] are left out of the answer.
Map<String, MergeStep> firstJoin({
  required Map<String, QuickDoc> local,
  required Map<String, QuickDoc> server,
  required int nowMs,
}) {
  QuickDoc stamp(Object? data, QuickDoc s) => QuickDoc(max(nowMs, s.at + 1), data);

  List<StripItem>? phrasesOf(QuickDoc? d) => d?.data is List ? [for (final e in d!.data as List) ?stripItemFromJson(e)] : null;

  // Phrases: the service's first, then what only this device has. Phrases are the same by text, commands by id.
  final remap = <String, String>{}; // local ref → service ref
  Object? phrasesData;
  final lp = phrasesOf(local['phrases']), sp = phrasesOf(server['phrases']);
  if (lp != null && sp != null) {
    final byText = {for (final it in sp) if (it is Phrase) it.text: it};
    final cmdIds = {for (final it in sp) if (it is StripCmd) it.id};
    final taken = {for (final it in sp) refOf(it)};
    final extra = <StripItem>[];
    for (final it in lp) {
      if (it is Phrase) {
        final twin = byText[it.text];
        if (twin != null) {
          if (it.id != null && twin.id != null && it.id != twin.id) remap['p:${it.id}'] = 'p:${twin.id}';
        } else if (taken.add(refOf(it))) {
          extra.add(it);
        } else if (it.id != null) {
          // The id is the service's for other text: keep the phrase under an id of its own.
          final fresh = it.withId(_derivedId(it.id!, it.text));
          remap['p:${it.id}'] = refOf(fresh);
          taken.add(refOf(fresh));
          extra.add(fresh);
        }
      } else if (it is StripCmd && !cmdIds.contains(it.id)) {
        extra.add(it);
      }
    }
    phrasesData = [for (final it in [...sp, ...extra]) it.toJson()];
  }

  String renamed(String ref) => remap[ref] ?? ref;

  final out = <String, MergeStep>{};
  for (final name in quickDocNames) {
    final l = local[name];
    if (l == null) continue;
    final s = server[name];
    if (s == null) {
      out[name] = Push(l, 0);
      continue;
    }
    final lOk = isDocReadable(name, l.data), sOk = isDocReadable(name, s.data);
    if (!sOk && lOk) {
      out[name] = Push(stamp(l.data, s), s.at);
      continue;
    }
    if (l.at == 0 || !lOk) {
      out[name] = Adopt(s);
      continue;
    }
    final Object? merged = switch (name) {
      'phrases' => phrasesData,
      'stars' => l.data is List && s.data is List
          ? {
              ...[for (final e in s.data as List) if (e is String) e],
              ...[for (final e in l.data as List) if (e is String) renamed(e)],
            }.toList()
          : null,
      'layout' => _mergeLayout(l.data, s.data),
      _ => null,
    };
    // A doc one side cannot read is the other side's.
    if (merged == null || jsonEncode(merged) == jsonEncode(s.data)) {
      out[name] = Adopt(s);
    } else {
      out[name] = Push(stamp(merged, s), s.at);
    }
  }
  return out;
}

/// The service's layout, unless it is the default and this device's is not (then this device's).
Object? _mergeLayout(Object? local, Object? server) {
  if (local is! Map || server is! Map) return null;
  final l = KeyLayout.fromJson(local), s = KeyLayout.fromJson(server);
  return (s.isDefault && !l.isDefault ? l : s).toJson();
}
