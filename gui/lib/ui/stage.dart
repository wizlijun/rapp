// The stage: where the remote window will sit. S1 shows a placeholder.
import 'package:flutter/material.dart';

import 'controls.dart';
import 'lamp.dart';
import 'main_state.dart';
import 'session_model.dart';
import 'tokens.dart';

class Stage extends StatelessWidget {
  const Stage({super.key, required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final theme = Theme.of(context).textTheme;
        final problem = state.hubProblem;
        final cur = state.current;
        Widget body;
        if (problem != null) {
          body = Text(problem, textAlign: TextAlign.center);
        } else if (cur == null) {
          body = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('打开左侧面板，选一个会话或到设备里打开 app',
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              RappButton.secondary(label: '打开面板', onPressed: state.togglePanel),
            ],
          );
        } else if (cur.lamp == Lamp.connecting) {
          body = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusLamp(cur.lamp),
              const SizedBox(width: 8),
              const Text('正在连接'),
            ],
          );
        } else {
          final path = pathLabels[cur.path];
          body = CustomPaint(
            foregroundPainter: _DashedBorder(t.line),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(cur.appName,
                      style: theme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(
                    '${cur.appName} 在单独的窗口里 · ${cur.device}'
                    '${path == null ? '' : ' · $path'}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.muted),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      RappButton.primary(
                        key: const Key('focus-button'),
                        label: '切到窗口',
                        onPressed: state.focusCurrent,
                      ),
                      // Keyed per session: an armed confirm never carries
                      // over to the session that becomes current next.
                      KeyedSubtree(
                        key: ValueKey('end:${cur.key}'),
                        child: ConfirmButton(
                          key: const Key('end-button'),
                          label: '结束会话',
                          onConfirmed: state.endCurrent,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }
        return Container(
          key: const Key('stage'),
          alignment: Alignment.center,
          padding: const EdgeInsets.all(16),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: t.text),
            child: body,
          ),
        );
      },
    );
  }
}

class _DashedBorder extends CustomPainter {
  _DashedBorder(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dash = 6.0, gap = 4.0;
    void line(Offset a, Offset b) {
      final d = b - a;
      final len = d.distance;
      final u = d / len;
      for (var x = 0.0; x < len; x += dash + gap) {
        canvas.drawLine(a + u * x, a + u * (x + dash).clamp(0, len), p);
      }
    }

    final r = Offset.zero & size;
    line(r.topLeft, r.topRight);
    line(r.topRight, r.bottomRight);
    line(r.bottomRight, r.bottomLeft);
    line(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(_DashedBorder o) => o.color != color;
}
