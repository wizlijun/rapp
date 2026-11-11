// Top bar: panel button, prev/next, current session, hint, fullscreen.
import 'package:flutter/material.dart';

import 'lamp.dart';
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
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final cur = state.current;
        final multi = state.sessionCount >= 2;
        final small = Theme.of(context).textTheme.bodySmall;
        return Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: t.bg,
            border: Border(bottom: BorderSide(color: t.line)),
          ),
          child: Row(
            children: [
              _icon('panel-button', Icons.menu, '面板', state.togglePanel),
              const SizedBox(width: 6),
              _icon('prev', Icons.chevron_left, '上一个',
                  multi ? () => state.step(-1) : null),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: cur == null
                    ? Text('没有选中的会话',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.muted))
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StatusLamp(cur.lamp),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(cur.appName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                Text(_sub(cur),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: small?.copyWith(color: t.muted)),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: 6),
              _icon('next', Icons.chevron_right, '下一个',
                  multi ? () => state.step(1) : null),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.muted),
                ),
              ),
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
  }

  String _sub(SessionEntry e) {
    final p = pathLabels[e.path];
    if (e.lamp == Lamp.connecting || p == null) {
      return e.lamp == Lamp.connecting ? '${e.device} · ${lampWord(e.lamp)}' : e.device;
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
