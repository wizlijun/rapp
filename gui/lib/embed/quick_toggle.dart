// The 快捷区 toggle (quick-toggle spec §1, §6, §8; bar-cmd addendum): one button beside 输入 (收起 while the text
// area is open), never in the writing box. Lit while the 快捷区 shows; each kind (terminal, app) keeps its own pref.
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

/// Where the toggle stands: in the iOS stage stack, or in the desktop corner row; beside 输入 either way.
enum QuickToggleLook { stage, corner }

class QuickToggle extends StatelessWidget {
  const QuickToggle({super.key, required this.state, required this.session, required this.look});

  final MainState state;
  final RemoteSession session;
  final QuickToggleLook look;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final shown = !quickHidden(state, session);
      final label = quickToggleLabel(shown: shown);
      void tap() => toggleQuick(state, session);
      final Widget button = switch (look) {
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
      return TextFieldTapRegion(
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: Listener(onPointerDown: (_) => state.holdForPanel(session), child: button),
        ),
      );
    },
  );
}
