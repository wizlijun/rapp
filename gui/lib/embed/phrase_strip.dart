// 常用语条 (iOS): the row of phrases on top of the key bar, 「全部 ›」 pinned at its right (phrases spec §2, §5).
// A tap sends ([sendPhrase]); a long press gives 放进输入框再改 / 编辑 / 移到最前 / 删除. Like the keys, nothing here
// takes the focus.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pages/phrases_page.dart';
import '../ui/controls.dart';
import '../ui/main_state.dart';
import '../ui/tokens.dart';
import 'composer_plus.dart';
import 'phrase_send.dart';
import 'phrases.dart';
import 'remote_session.dart';
import 'session_port.dart';

class PhraseStrip extends StatefulWidget {
  const PhraseStrip({super.key, required this.state, required this.session, required this.port});

  final MainState state;
  final RemoteSession session;
  final SessionPort port;

  @override
  State<PhraseStrip> createState() => _PhraseStripState();
}

class _PhraseStripState extends State<PhraseStrip> {
  /// The chip that just went, shown with ✓ for [phraseTickTime].
  int? _ticked;
  String? _hint;
  Timer? _tickTimer, _hintTimer;

  @override
  void dispose() {
    _tickTimer?.cancel();
    _hintTimer?.cancel();
    super.dispose();
  }

  List<Phrase> get _list => widget.state.prefs.phrases;

  /// One tap on [p] (the [i]th; null from the 全部 sheet).
  PhraseOutcome _tap(Phrase p, int? i) {
    final o = sendPhrase(state: widget.state, session: widget.session, port: widget.port, p: p);
    if (!mounted) return o;
    switch (o) {
      case PhraseOutcome.sent:
        unawaited(HapticFeedback.lightImpact());
        _tickTimer?.cancel();
        setState(() => _ticked = i);
        _tickTimer = Timer(phraseTickTime, () {
          if (mounted) setState(() => _ticked = null);
        });
      case PhraseOutcome.offline || PhraseOutcome.busy:
        _say(phraseHint(o)!);
      case PhraseOutcome.put || PhraseOutcome.tooSoon:
        break;
    }
    return o;
  }

  void _say(String hint) {
    _hintTimer?.cancel();
    setState(() => _hint = hint);
    _hintTimer = Timer(phraseHintTime, () {
      if (mounted) setState(() => _hint = null);
    });
  }

  Future<void> _menu(int i, Offset at) async {
    final p = _list[i];
    final pick = await showRappMenu<String>(context, position: menuAt(context, at), items: const [
      RappMenuItem(value: 'put', key: Key('phrase-menu-put'), label: '放进输入框再改'),
      RappMenuItem(value: 'edit', key: Key('phrase-menu-edit'), label: '编辑'),
      RappMenuItem(value: 'first', key: Key('phrase-menu-first'), label: '移到最前'),
      RappMenuItem(value: 'delete', key: Key('phrase-menu-delete'), label: '删除'),
    ]);
    if (!mounted || pick == null) return;
    final l = List.of(_list);
    final at0 = l.indexOf(p);
    if (at0 < 0) return; // changed meanwhile
    switch (pick) {
      case 'put':
        putIntoComposer(widget.session, p.text);
      case 'edit':
        final e = await editPhrase(context, p: p);
        if (e == null) return;
        final now = List.of(_list);
        final j = now.indexOf(p);
        if (j >= 0) widget.state.setPhrases(now..[j] = e);
      case 'first':
        widget.state.setPhrases([p, ...l..removeAt(at0)]);
      case 'delete':
        widget.state.setPhrases(l..removeAt(at0));
    }
  }

  Future<void> _all() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: RappTokens.of(context).bg,
        builder: (sheet) {
          final t = RappTokens.of(sheet);
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * .6),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(children: [
                    Expanded(child: Text('常用语', style: TextStyle(color: t.text, fontSize: t.textSize + 2))),
                    RappButton.quiet(
                      key: const Key('phrases-all-edit'),
                      label: '编辑',
                      onPressed: () {
                        Navigator.of(sheet).pop();
                        openPhrasesPage(context, widget.state);
                      },
                    ),
                  ]),
                ),
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    for (final (i, p) in _list.indexed)
                      ListTile(
                        key: Key('phrases-all-$i'),
                        title: Text(p.text, style: TextStyle(color: t.text)),
                        trailing: p.put ? Icon(Icons.keyboard_return, color: t.muted, size: 18) : null,
                        onTap: () {
                          final o = _tap(p, i);
                          if (o == PhraseOutcome.sent || o == PhraseOutcome.put) Navigator.of(sheet).pop();
                        },
                      ),
                  ]),
                ),
              ]),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([widget.state, widget.session.composer]),
      builder: (context, _) {
        final blocked = phraseBlock(widget.state, widget.session) != null;
        final hint = _hint;
        Widget chip(Key key, String label, {required VoidCallback onTap, GestureLongPressStartCallback? onLong,
            bool ticked = false, bool put = false}) {
          final color = ticked ? t.on : t.line;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              key: key,
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              onLongPressStart: onLong,
              child: Container(
                height: phraseStripChip,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: ticked ? Color.alphaBlend(t.on.withValues(alpha: .18), t.raise.first) : t.raise.first,
                  borderRadius: BorderRadius.circular(phraseStripChip / 2),
                  border: Border.all(color: color, width: ticked ? 2 : 1),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (ticked) ...[Icon(Icons.check, size: 14, color: t.on), const SizedBox(width: 3)],
                  Text(label, maxLines: 1, style: TextStyle(fontSize: 13, color: t.text)),
                  if (put) ...[const SizedBox(width: 3), Icon(Icons.keyboard_return, size: 12, color: t.muted)],
                ]),
              ),
            ),
          );
        }

        final list = _list;
        return SizedBox(
          height: phraseStripChip,
          child: Row(children: [
            Expanded(
              child: hint != null
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Text(hint, key: const Key('phrase-hint'), style: TextStyle(color: t.muted, fontSize: 13)),
                    )
                  : Opacity(
                      opacity: blocked ? .4 : 1,
                      child: ListView(
                        key: const Key('phrase-strip-list'),
                        scrollDirection: Axis.horizontal,
                        padding: EdgeInsets.zero,
                        children: [
                          for (final (i, p) in list.indexed)
                            chip(Key('phrase-$i'), p.text,
                                ticked: _ticked == i,
                                put: p.put,
                                onTap: () => _tap(p, i),
                                onLong: (d) => _menu(i, d.globalPosition)),
                        ],
                      ),
                    ),
            ),
            chip(const Key('phrases-all'), '全部 ›', onTap: _all),
          ]),
        );
      },
    );
  }
}
