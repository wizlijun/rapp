import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';
import 'waits.dart';

/// The card over the stage while something slow is waited for (a new text terminal, a restore): a spinner, what it
/// is, on what, how many seconds so far and what else waits; then a failure's words for a few seconds. It takes no
/// taps and no keys: everything under it goes on working.
class WaitCard extends StatefulWidget {
  const WaitCard({super.key, required this.waits});
  final Waits waits;

  @override
  State<WaitCard> createState() => _WaitCardState();
}

class _WaitCardState extends State<WaitCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    widget.waits.addListener(_changed);
  }

  @override
  void didUpdateWidget(WaitCard old) {
    super.didUpdateWidget(old);
    if (old.waits != widget.waits) {
      old.waits.removeListener(_changed);
      widget.waits.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.waits.removeListener(_changed);
    _tick?.cancel();
    super.dispose();
  }

  void _changed() {
    // The seconds tick only while something is shown.
    if (widget.waits.shown.isEmpty) {
      _tick?.cancel();
      _tick = null;
    } else {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.waits;
    final shown = w.shown;
    final outcome = w.outcome;
    if (shown.isEmpty && outcome == null) return const SizedBox.shrink();
    final t = RappTokens.of(context);
    final first = shown.firstOrNull;
    final more = w.moreLine;
    final small = TextStyle(color: t.muted, fontSize: 12);
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, -0.5),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            key: const Key('wait-card'),
            padding: const EdgeInsets.all(12),
            decoration: t.floatBox(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (outcome != null)
                  Text(
                    outcome.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: outcome.asks ? t.warn : t.text),
                  ),
                if (outcome != null && first != null) const SizedBox(height: 8),
                if (first != null)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: t.on)),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(first.what, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text)),
                    ),
                    const SizedBox(width: 12),
                    Text('${clock.now().difference(first.started).inSeconds} 秒', style: small),
                  ]),
                if (first?.detail case final d?)
                  Padding(
                    padding: const EdgeInsets.only(left: 26, top: 2),
                    child: Text(d, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                  ),
                if (more != null)
                  Padding(
                    padding: EdgeInsets.only(left: first == null ? 0 : 26, top: 2),
                    child: Text(more, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
