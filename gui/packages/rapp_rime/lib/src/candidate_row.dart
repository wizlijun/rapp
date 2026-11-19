import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'rapp_rime.dart';

/// One-row candidate strip with local pagination, plus the 中/英 marker and the
/// 内/系 switch at the right end. Trimmed from the Linux candidate surface.
class RimeCandidateRow extends StatelessWidget {
  const RimeCandidateRow({super.key, required this.link, required this.menu, required this.style});
  final RimeLink link;
  final RimeMenu menu;
  final TextStyle style;

  /// Row height: the line height of 「字Mg」 in [style] plus 13.
  static double heightFor(BuildContext context, TextStyle style) => _lineHeight(context, _resolve(context, style)) + 13;

  static TextStyle _resolve(BuildContext context, TextStyle style) =>
      DefaultTextStyle.of(context).style.merge(style).copyWith(inherit: false, shadows: const []);

  static double _lineHeight(BuildContext context, TextStyle style) => (TextPainter(
    text: TextSpan(text: '字Mg', style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
  )..layout()).height;

  @override
  Widget build(BuildContext context) {
    final textStyle = _resolve(context, style);
    final height = _lineHeight(context, textStyle);
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) => SizedBox(
        height: height + 13,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _line(height, _body(context, textStyle, height))),
            ..._tail(textStyle, height),
          ],
        ),
      ),
    );
  }

  /// The text sits on the first [height] of the row; the 13 below are spacing.
  static Widget _line(double height, Widget child) =>
      Align(alignment: Alignment.topLeft, child: SizedBox(height: height, child: child));

  /// The 内/系 toggle's least width: a finger-sized target.
  static const toggleWidth = 44.0;

  Widget _body(BuildContext context, TextStyle textStyle, double height) {
    if (menu.rows.isNotEmpty) {
      return _Candidates(link: link, menu: menu, style: textStyle, height: height);
    }
    final status = link.status;
    if (status.state == RimeState.starting) {
      return Text('部署中…', maxLines: 1, style: textStyle.copyWith(color: _muted(textStyle).color));
    }
    if (status.state == RimeState.error) {
      return Text(
        '出错：${status.message}',
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: textStyle.copyWith(color: _muted(textStyle).color),
      );
    }
    return const SizedBox.shrink();
  }

  static TextStyle _muted(TextStyle s) => s.copyWith(color: (s.color ?? const Color(0xff888888)).withValues(alpha: .65));

  /// The 中/英 marker, then the toggle, which spans the whole row height and at least [toggleWidth].
  List<Widget> _tail(TextStyle textStyle, double height) {
    final muted = _muted(textStyle);
    return [
      _line(
        height,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Center(
            widthFactor: 1,
            child: Text(link.ascii ? '英' : '中', key: const Key('rime-ascii'), style: muted),
          ),
        ),
      ),
      Semantics(
        button: true,
        label: '切换内置输入法',
        excludeSemantics: true,
        child: GestureDetector(
          key: const Key('rime-toggle'),
          behavior: HitTestBehavior.opaque,
          onTap: link.toggleBuiltin,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: toggleWidth),
            child: _line(
              height,
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Center(widthFactor: 1, child: Text(link.builtin ? '内' : '系', style: textStyle)),
              ),
            ),
          ),
        ),
      ),
    ];
  }
}

class _Candidates extends StatefulWidget {
  const _Candidates({required this.link, required this.menu, required this.style, required this.height});
  final RimeLink link;
  final RimeMenu menu;
  final TextStyle style;
  final double height;
  @override
  State<_Candidates> createState() => _CandidatesState();
}

class _CandidatesState extends State<_Candidates> {
  int page = 0;
  String? pagedKey;

  @override
  void didUpdateWidget(_Candidates old) {
    super.didUpdateWidget(old);
    if (!identical(old.menu, widget.menu)) pagedKey = null;
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style, menu = widget.menu;
    final muted = RimeCandidateRow._muted(style);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    double measure(String text, TextStyle s) => (TextPainter(
      text: TextSpan(text: text, style: s),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout()).width;
    final navigation = math.max(widget.height * 2.5, measure('‹  ›', style) + measure('  ', style));
    final gap = math.max(2.0, measure('  ', style));

    TextSpan span(RimeCandidate c) => TextSpan(
      style: style,
      children: [
        TextSpan(text: '${c.label} ', style: muted),
        TextSpan(
          text: c.text,
          style: style.copyWith(decoration: c.index == menu.cursor ? TextDecoration.underline : TextDecoration.none),
        ),
      ],
    );
    double natural(RimeCandidate c) =>
        (TextPainter(text: span(c), textDirection: TextDirection.ltr, textScaler: scaler, locale: locale)..layout())
            .width
            .ceilToDouble() +
        gap;

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = math.max(0.0, constraints.maxWidth - navigation);
        final pages = <List<RimeCandidate>>[];
        var row = <RimeCandidate>[], used = 0.0;
        for (final c in menu.rows) {
          final w = natural(c);
          if (row.isNotEmpty && used + w > available) {
            pages.add(row);
            row = [];
            used = 0;
          }
          row.add(c);
          used += w.clamp(0, available);
        }
        if (row.isNotEmpty) pages.add(row);
        final key = '$available/${widget.height}/${style.hashCode}';
        if (pagedKey != key) {
          pagedKey = key;
          final selected = pages.indexWhere((rows) => rows.any((r) => r.index == menu.cursor));
          page = selected < 0 ? 0 : selected;
        }
        page = page.clamp(0, pages.length - 1);
        final shown = pages[page];

        Widget arrow(bool next) {
          final local = next ? page + 1 < pages.length : page > 0;
          final enabled = local || (next ? menu.next : menu.previous);
          return SizedBox(
            width: navigation / 2,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: !enabled
                  ? null
                  : () {
                      if (local) {
                        setState(() => page += next ? 1 : -1);
                      } else {
                        widget.link.page(next);
                      }
                    },
              child: Semantics(
                button: true,
                label: next ? '下一页候选' : '上一页候选',
                enabled: enabled,
                child: Text(
                  next ? '›' : '‹',
                  textAlign: TextAlign.center,
                  style: enabled ? style : muted.copyWith(color: Colors.transparent),
                ),
              ),
            ),
          );
        }

        return Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  for (final c in shown)
                    SizedBox(
                      width: math.min(available, natural(c)),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => widget.link.select(c.index),
                        child: Semantics(
                          button: true,
                          label: c.text,
                          child: Padding(
                            padding: EdgeInsets.only(right: gap),
                            child: Text.rich(
                              span(c),
                              style: style,
                              textDirection: TextDirection.ltr,
                              textScaler: scaler,
                              locale: locale,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            arrow(false),
            arrow(true),
          ],
        );
      },
    );
  }
}
