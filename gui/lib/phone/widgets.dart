/// Shared building blocks of the phone shell (V1b Task 5). Tokens only (T1).
library;

import 'package:flutter/material.dart';

import '../ui/lamp.dart';
import '../ui/tokens.dart';
import 'home_model.dart';

const phoneMaxWidth = 480.0;
const phoneTap = 56.0;
const phonePrimaryTap = 64.0;

const offlineLine = '连不上，通了自动恢复';

/// The page frame: background, safe area, content centred at most [phoneMaxWidth] wide (F4).
class PhonePage extends StatelessWidget {
  const PhonePage({super.key, required this.child, this.title, this.onBack, this.offline = false});
  final Widget child;
  final String? title;
  final VoidCallback? onBack;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium;
    return ColoredBox(
      color: t.bg,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: phoneMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (offline)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                    child: Text(offlineLine, style: style?.copyWith(color: t.muted)),
                  ),
                if (onBack != null || title != null)
                  SizedBox(
                    height: phoneTap,
                    child: Row(
                      children: [
                        if (onBack != null)
                          InkWell(
                            onTap: onBack,
                            child: Container(
                              constraints: const BoxConstraints(minWidth: phoneTap),
                              height: phoneTap,
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: Text('返回', style: style?.copyWith(color: t.text)),
                            ),
                          ),
                        if (title != null)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: Text(title!, style: style?.copyWith(color: t.text, fontWeight: FontWeight.w600)),
                            ),
                          ),
                      ],
                    ),
                  ),
                // Q2: the back button and what is under it are 12 apart.
                if (onBack != null || title != null) const SizedBox(height: 12),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PhoneButton extends StatelessWidget {
  const PhoneButton({super.key, required this.label, this.onPressed, this.primary = false, this.tall = false});
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  /// A button on a card (and a primary one) is [phonePrimaryTap] high, others [phoneTap].
  final bool tall;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium;
    final deco = primary
        ? BoxDecoration(color: t.text, borderRadius: BorderRadius.circular(t.r), border: Border.all(color: t.text))
        : t.raiseBox();
    return Opacity(
      opacity: onPressed == null ? 0.4 : 1,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: label,
        excludeSemantics: true,
        onTap: onPressed,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: Container(
            constraints: BoxConstraints(minHeight: primary || tall ? phonePrimaryTap : phoneTap),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            alignment: Alignment.center,
            decoration: deco,
            child: Text(
              label,
              textAlign: TextAlign.center,
              softWrap: true,
              style: style?.copyWith(color: primary ? t.bg : t.text, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}

String _source(HomeItem i) => [i.what, if (i.program.isNotEmpty) i.program, if (i.device.isNotEmpty) i.device].join(' · ');

String buttonLabel(HomeButton b) => switch (b) {
      HomeButton.goLook => '进去看',
      HomeButton.reconnect => '重连',
      HomeButton.gotIt => '知道了',
    };

/// A compact list row: lamp, `what · program · device`, then the line.
class PhoneRow extends StatelessWidget {
  const PhoneRow({super.key, required this.item, required this.onTap});
  final HomeItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium;
    // Q2: two rows to tap are 12 apart.
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        excludeSemantics: true,
        label: '${item.what}，${item.program} 在 ${item.device}，${item.line}',
        onTap: onTap,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: phoneTap),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.line.withValues(alpha: 0.5)))),
            child: Row(
              children: [
                StatusLamp(item.lamp),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_source(item), style: style?.copyWith(color: t.text)),
                      if (item.line.isNotEmpty) Text(item.line, style: style?.copyWith(color: t.muted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One thing that needs a look: source line (C1), the line, at most one button (C3).
class PhoneCard extends StatelessWidget {
  const PhoneCard({super.key, required this.item, required this.onOpen, required this.onButton});
  final HomeItem item;
  final VoidCallback? onOpen;
  final VoidCallback? onButton;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium;
    final waiting = item.kind == HomeKind.waiting;
    final deco = BoxDecoration(
      color: waiting ? t.tint : t.panel.first,
      borderRadius: BorderRadius.circular(t.r),
      border: Border.all(color: waiting ? t.accent : t.line),
    );
    final open = item.sessionKey == null ? null : onOpen;
    return Semantics(
      container: true,
      label: '${item.what}，${item.program} 在 ${item.device}，${item.line}',
      onTap: open,
      child: DecoratedBox(
        decoration: deco,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: InkWell(
                  onTap: open,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: phoneTap),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            StatusLamp(item.lamp),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _source(item),
                                style: style?.copyWith(color: waiting ? t.accent : t.text, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                        if (item.line.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(item.line, style: style?.copyWith(color: t.text)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              PhoneButton(label: buttonLabel(item.button), onPressed: onButton, tall: true),
            ],
          ),
        ),
      ),
    );
  }
}
