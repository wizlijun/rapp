// The 快捷区 toggle (quick-toggle spec §1, §6, §8): a square key beside ＋ in the writing box, or beside 输入 while
// the text area is folded. Lit while the 快捷区 shows; each kind (terminal, app) keeps its own pref.
import 'package:flutter/material.dart';

import '../ui/controls.dart';
import '../ui/main_state.dart';
import 'key_bar.dart';
import 'remote_session.dart';
import 'stage_buttons.dart' show stageButtonSize;

/// What the toggle does, said from where the 快捷区 is now.
String quickToggleLabel({required bool shown}) => shown ? '收起快捷区' : '显示快捷区';

/// Shows the 快捷区 of [session]'s kind if it is hidden, else hides it.
void toggleQuick(MainState state, RemoteSession session) =>
    state.setQuickHidden(term: termKind(state, session), hidden: !quickHidden(state, session));

/// Where the toggle stands: in the box (like ＋), in the iOS stage stack (like 输入), or in the desktop corner row.
enum QuickToggleLook { box, stage, corner }

class QuickToggle extends StatelessWidget {
  const QuickToggle({super.key, required this.state, required this.session, required this.look, this.scale = 1});

  final MainState state;
  final RemoteSession session;
  final QuickToggleLook look;

  /// The writing panel's zoom: the box look is 40 × [scale] square, like ＋ and 发送.
  final double scale;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final shown = !quickHidden(state, session);
      final label = quickToggleLabel(shown: shown);
      void tap() => toggleQuick(state, session);
      final Widget button = switch (look) {
        QuickToggleLook.box => RappButton.secondary(
          key: const Key('quick-toggle'),
          label: label,
          semanticLabel: label,
          icon: Icons.grid_view_outlined,
          size: 40 * scale,
          active: shown,
          onPressed: tap,
        ),
        QuickToggleLook.stage => RappButton.stage(
          key: const Key('quick-toggle-stack'),
          label: label,
          icon: Icons.grid_view_outlined,
          size: stageButtonSize,
          active: shown,
          onPressed: tap,
        ),
        QuickToggleLook.corner => RappButton.secondary(
          key: const Key('quick-toggle-stack'),
          label: label,
          semanticLabel: label,
          icon: Icons.grid_view_outlined,
          onPicture: true,
          seeThrough: true,
          active: shown,
          onPressed: tap,
        ),
      };
      // Pressing it keeps the keys with the panel, as ＋ does: the picture must not take them back. Part of the
      // text field for taps, so a mouse click (Linux, macOS) does not take the caret out of the text. The button
      // names itself; the tooltip is for the eye only.
      final Widget held = TextFieldTapRegion(
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: Listener(onPointerDown: (_) => state.holdForPanel(session), child: button),
        ),
      );
      // Beside 输入 it comes as the box folds away over its own animation: a short fade, not a pop.
      return look == QuickToggleLook.box ? held : _FadeIn(child: held);
    },
  );
}

/// Fades [child] in once, when it enters the tree; at once under reduced motion.
class _FadeIn extends StatelessWidget {
  const _FadeIn({required this.child});

  final Widget child;

  static const _duration = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: MediaQuery.disableAnimationsOf(context) ? 1 : 0, end: 1),
    duration: _duration,
    curve: Curves.easeOut,
    builder: (context, t, child) => Opacity(key: const Key('quick-toggle-fade'), opacity: t, child: child),
    child: child,
  );
}
