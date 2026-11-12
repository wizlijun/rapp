// 「需要你」: the top bar's count of what waits for the person (dropped sessions, dropped devices)
// and the popover that lists it. The only thing that may come looking for the person is 等你 (§0),
// so nothing here opens by itself.
import 'package:flutter/material.dart';

import 'controls.dart';
import 'corner_popover.dart';
import 'lamp.dart';
import 'main_state.dart';
import 'tokens.dart';

class NeedsYouAnchor extends StatefulWidget {
  const NeedsYouAnchor({super.key, required this.state});

  final MainState state;

  @override
  State<NeedsYouAnchor> createState() => _NeedsYouAnchorState();
}

class _NeedsYouAnchorState extends State<NeedsYouAnchor> {
  MainState get _s => widget.state;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return ListenableBuilder(
      listenable: _s,
      builder: (context, _) => CornerPopover(
        open: _s.corner == Corner.needs,
        onClose: _s.closeCorner,
        scrimKey: const Key('needs-scrim'),
        popover: _NeedsList(state: _s),
        child: _button(t),
      ),
    );
  }

  Widget _button(RappTokens t) {
    final needs = _s.needs;
    final n = needs.length;
    final sessions = needs.any((x) => x.kind == NeedKind.session);
    final lamp = sessions ? Lamp.disconnected : (n > 0 ? Lamp.offline : Lamp.active);
    final open = _s.corner == Corner.needs;
    final radius = BorderRadius.circular(t.r);
    final back = n == 0 ? null : rowBackdrop(lamp, t);
    final border = open ? t.text : (sessions ? t.accent : (n > 0 ? t.line : Colors.transparent));
    return Semantics(
      button: true,
      selected: open,
      label: n == 0 ? '需要你：没有' : '需要你：$n 件',
      excludeSemantics: true,
      onTap: () => _s.toggleCorner(Corner.needs),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const Key('needs-you'),
          onTap: () => _s.toggleCorner(Corner.needs),
          borderRadius: radius,
          child: Container(
            width: 48, // fixed: the bar reserves exactly this; a long count scales down instead of growing
            constraints: const BoxConstraints(minHeight: 48),
            decoration: BoxDecoration(borderRadius: radius, border: Border.all(color: border)),
            child: ClipRRect(
              borderRadius: radius,
              child: DecoratedBox(
                decoration: back ?? const BoxDecoration(),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 46),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StatusLamp(lamp),
                      if (n > 0) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '$n',
                              key: const Key('needs-count'),
                              style: TextStyle(
                                fontFamily: t.mono,
                                fontFamilyFallback: t.monoFallback,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: t.text,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NeedsList extends StatelessWidget {
  const _NeedsList({required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final needs = state.needs;
    if (needs.isEmpty) {
      return Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          const StatusLamp(Lamp.active),
          const SizedBox(width: 8),
          Expanded(child: Text('没有需要你处理的事', style: TextStyle(color: t.muted))),
        ]),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final n in needs.take(3)) _row(t, n),
          if (needs.length > 3)
            Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.centerLeft,
              child: Text('还有 ${needs.length - 3} 件', style: TextStyle(color: t.muted)),
            ),
        ],
      ),
    );
  }

  Widget _row(RappTokens t, NeedItem n) {
    final session = n.kind == NeedKind.session;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(children: [
        Expanded(child: Text(n.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text))),
        const SizedBox(width: 8),
        if (session)
          RappButton.accent(
            key: Key('need-reconnect-${n.target}'),
            label: n.reconnectWord,
            onPressed: state.hubUsable
                ? () {
                    state.reconnect(n.target);
                    state.closeCorner();
                  }
                : null,
          )
        else
          RappButton.secondary(
            key: Key('need-show-${n.target}'),
            label: '查看',
            onPressed: () => state.showDevice(n.target),
          ),
      ]),
    );
  }
}
