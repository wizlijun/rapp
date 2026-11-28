// How big the input controls are: the key bar's keys, the phrase strip's chips, and the composer panel's ＋ and 发送.
// The Pad and macOS draw the standard sizes (today's constants); a phone session wraps its layer in [InputMetrics.phone]
// so every tappable is at least 56 high with at least 12 between neighbours (V1c R36).
import 'package:flutter/widgets.dart';
import 'key_bar_keys.dart';
import 'phrases.dart';

/// The one place that holds the sizes. [standard] is built from today's constants, so there is a single source of truth.
class InputMetrics extends InheritedWidget {
  const InputMetrics({
    super.key,
    required this.keyHeight,
    required this.gap,
    required this.chip,
    required this.panelButton,
    this.boxEdge = 0,
    required super.child,
  });

  /// The key bar's key height (the brief's `key`; renamed so it does not clash with [Widget.key]).
  final double keyHeight;

  /// The gap between keys (rows and columns).
  final double gap;

  /// The phrase strip's chip height (命令▾ and 常用语▾ included).
  final double chip;

  /// The composer panel's ＋ and 发送, at zoom 1.
  final double panelButton;

  /// Extra height for the key bar's box, so its 1-point border does not eat into the keys: 0 as today (the keys are
  /// then 2 short of [keyHeight]), 2 on the phone (the keys are a full 56).
  final double boxEdge;

  static const standard = InputMetrics._values(keyBarKeyHeight, keyBarGap, phraseStripChip, 40.0, 0);
  static const phone = InputMetrics._values(56, 12, 56, 56, 2);

  const InputMetrics._values(this.keyHeight, this.gap, this.chip, this.panelButton, this.boxEdge) : super(child: const SizedBox());

  /// Wraps [child] in these sizes.
  Widget wrap(Widget child) =>
      InputMetrics(keyHeight: keyHeight, gap: gap, chip: chip, panelButton: panelButton, boxEdge: boxEdge, child: child);

  /// The sizes in force at [context]: [standard] when nothing above sets them.
  static InputMetrics of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InputMetrics>() ?? standard;

  @override
  bool updateShouldNotify(InputMetrics old) =>
      keyHeight != old.keyHeight || gap != old.gap || chip != old.chip || panelButton != old.panelButton || boxEdge != old.boxEdge;
}

/// The strip's gap to the keys and between chips never drops under today's 6.
double stripGapOf(InputMetrics m) => m.gap > phraseStripGap ? m.gap : phraseStripGap;

/// The strip's height inside the bar: its chips and the gap to the keys.
double stripHeightFor(InputMetrics m) => m.chip + stripGapOf(m);

/// The key bar's height for [rows] rows: the keys, the gaps between rows and the bar's padding.
double keyBarHeightFor(InputMetrics m, int rows) => rows * m.keyHeight + (rows - 1) * m.gap + 2 * keyBarPad + m.boxEdge;
