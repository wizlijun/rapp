// Top bar: panel button, prev/next, current session, hint, fullscreen.
import 'package:flutter/material.dart';

import 'lamp.dart';
import 'tab_chip.dart';
import 'main_state.dart';
import 'session_model.dart';
import 'tokens.dart';

class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.state,
    required this.fullscreen,
    required this.onToggleFullscreen,
  });

  final MainState state;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 480;
        final gap = box.maxWidth >= 300 ? 6.0 : 0.0;
        // The session block is a fixed-max, non-flex child so the hint's
        // Expanded takes all the slack and the fullscreen button stays at the
        // right edge. (A loose Flexible would leave its unused share of the
        // slack at the end of the row.)
        final sessionMax =
            (box.maxWidth - 4 * 48 - 6 * gap).clamp(0.0, 260.0).toDouble();
        return ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            final cur = state.current;
            final tabs = state.currentRemote?.tabs;
            final multi = state.sessionCount >= 2;
            final small = Theme.of(context).textTheme.bodySmall;
            return Container(
              height: 56,
              padding: EdgeInsets.symmetric(horizontal: gap),
              decoration: BoxDecoration(
                color: t.bg,
                border: Border(bottom: BorderSide(color: t.line)),
              ),
              child: Row(
                children: [
                  _icon('panel-button', Icons.menu, '面板', state.togglePanel),
                  SizedBox(width: gap),
                  _icon(
                    'prev',
                    Icons.chevron_left,
                    '上一个',
                    multi ? () => state.step(-1) : null,
                  ),
                  SizedBox(width: gap),
                  ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: sessionMax),
                      child: cur == null
                          ? Text(
                              '没有选中的会话',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: t.muted),
                            )
                          : Semantics(
                              container: true,
                              excludeSemantics: true,
                              label:
                                  '${cur.appName}，${lampWord(cur.lamp)}，${_sub(cur)}',
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  StatusLamp(cur.lamp),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          cur.appName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          _sub(cur),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: small?.copyWith(
                                            color: t.muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                  ),
                  SizedBox(width: gap),
                  _icon(
                    'next',
                    Icons.chevron_right,
                    '下一个',
                    multi ? () => state.step(1) : null,
                  ),
                  SizedBox(width: gap),
                  if (tabs != null && tabs.tabs.length >= 2)
                    Flexible(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final w in tabs.tabs)
                              Padding(
                                padding: EdgeInsets.only(right: gap),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 200),
                                  child: IntrinsicWidth(
                                    child: TabChip(
                                    label: w.title.isEmpty ? cur!.appName : w.title,
                                    selected: w.id == tabs.current,
                                    onTap: () => state.selectWindow(w.id),
                                  ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (wide)
                    Expanded(
                      child: Text(
                        state.hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.muted),
                      ),
                    )
                  else
                    const Spacer(),
                  _icon(
                    'fullscreen-button',
                    fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    fullscreen ? '退出全屏' : '进入全屏',
                    onToggleFullscreen,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _sub(SessionEntry e) {
    final p = pathLabels[e.path];
    if (e.lamp == Lamp.connecting || p == null) {
      return e.lamp == Lamp.connecting
          ? '${e.device} · ${lampWord(e.lamp)}'
          : e.device;
    }
    return '${e.device} · $p';
  }

  Widget _icon(String key, IconData icon, String tip, VoidCallback? onTap) {
    return IconButton(
      key: Key(key),
      icon: Icon(icon),
      tooltip: tip,
      onPressed: onTap,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    );
  }
}
