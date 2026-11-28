import '../embed/strip_tools.dart';
import '../hub_client.dart' show TermRow;
import '../ui/main_state.dart' show DeviceProbe;
import 'home_model.dart';
import 'reply_table.dart';

/// Whether device [id] can answer a session without a view (its `apps` capabilities carry `reply`).
bool deviceCanReply(Map<String, DeviceProbe> probes, String id) => probes[id]?.apps?.capabilities?['reply'] == true;

enum ReplyKind { approve, options, review, done, none }

/// The session a reply goes to: device id and terminal id.
class ReplyTarget {
  const ReplyTarget(this.device, this.term);
  final String device, term;

  @override
  bool operator ==(Object other) => other is ReplyTarget && other.device == device && other.term == term;

  @override
  int get hashCode => Object.hash(device, term);
}

/// Which buttons a phone card gets, and the keys behind them.
class CardReply {
  const CardReply(this.kind,
      {this.target,
      this.seq,
      this.allow,
      this.deny,
      this.options = const [],
      this.planOk,
      this.planRevise,
      this.plain,
      this.risk,
      this.quote,
      this.voice = false});

  const CardReply.none() : this(ReplyKind.none);

  final ReplyKind kind;
  final ReplyTarget? target;
  final int? seq;
  final List<String>? allow, deny;

  /// Option labels, in the order the program shows them.
  final List<String> options;
  final List<String>? planOk, planRevise;
  final String? plain;
  final ({String word, String why})? risk;
  final String? quote;
  final bool voice;

  /// The keys that pick option [index] (0-based): the program numbers them from 1.
  List<String> optionKeys(int index) => ['${index + 1}'];
}

/// Decides the reply buttons of [item]. Only a waiting or done terminal card with a row on a device that can answer
/// without a view gets any; everything else is go-look only.
CardReply replyOf(HomeItem item, {required TermRow? row, required bool deviceReply}) {
  if (item.kind != HomeKind.waiting && item.kind != HomeKind.done) return const CardReply.none();
  final parts = item.id.split('\n');
  if (parts.length != 3 || parts[0] != 'term' || row == null || !row.reply || !deviceReply) return const CardReply.none();
  final target = ReplyTarget(parts[1], parts[2]);
  final seq = row.ps?.seq;
  if (item.kind == HomeKind.done) return CardReply(ReplyKind.done, target: target, seq: seq, voice: true);
  final tool = toolOf(row);
  final keys = toolKeysOf(tool);
  if (tool == null || keys == null) return const CardReply.none();
  final ask = parseAsk(tool, row.ps?.kind, row.ps?.msg ?? '');
  switch (ask) {
    case AskApprove a:
      final allow = keys.allow;
      if (allow == null) return const CardReply.none();
      final deny = keys.deny ?? denyKeysFor(tool, row.ps?.msg ?? '');
      return CardReply(ReplyKind.approve,
          target: target,
          seq: seq,
          allow: allow,
          deny: deny.isEmpty ? null : deny,
          plain: plainWords(a.target) ?? plainWordsForTool(a.tool),
          risk: _risk(a.target),
          quote: a.target);
    case AskOptions o:
      if (!keys.options) return const CardReply.none();
      return CardReply(ReplyKind.options, target: target, seq: seq, options: o.options);
    case AskPlan _:
      final points = item.points;
      if (keys.planOk == null || keys.planRevise == null || points == null || points.isEmpty) {
        return const CardReply.none();
      }
      return CardReply(ReplyKind.review, target: target, seq: seq, planOk: keys.planOk, planRevise: keys.planRevise);
    case null:
      return const CardReply.none();
  }
}

/// The card's warning: the label is always 撤不回, the reason comes from the table.
({String word, String why})? _risk(String command) {
  final r = riskOf(command);
  return r == null ? null : (word: '撤不回', why: r.why);
}
