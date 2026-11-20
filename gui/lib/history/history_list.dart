// The 「输入历史」 list (spec 2026-11-14-rapp-input-history R4, R5): search over every device's
// input record, three scopes, one line per entry with 放进输入框 / 复制到本机 / 从记录里去掉 in its ⋮ menu.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/controls.dart';
import '../ui/tab_chip.dart';
import '../ui/tokens.dart';
import 'input_history.dart';

/// How many matches show at a time, and how many 「再显示」 adds.
const historyPage = 200;

enum _Scope { session, host, all }

class InputHistoryList extends StatefulWidget {
  const InputHistoryList({
    super.key,
    required this.history,
    this.session,
    this.host,
    this.onPut,
    this.clock = DateTime.now,
  });

  final InputHistory history;

  /// The session key (`host/app`) the 「这个会话」 scope narrows to; null: that scope is off.
  final String? session;

  /// The host id the 「这台主机」 scope narrows to; null: that scope is off.
  final String? host;

  /// 放进输入框; null: that action cannot be pressed.
  final void Function(String text)? onPut;

  final DateTime Function() clock;

  @override
  State<InputHistoryList> createState() => _InputHistoryListState();
}

class _InputHistoryListState extends State<InputHistoryList> {
  final _query = TextEditingController();
  late _Scope _scope;
  int _limit = historyPage;

  bool _can(_Scope s) => switch (s) {
        _Scope.session => widget.session != null,
        _Scope.host => widget.host != null,
        _Scope.all => true,
      };

  _Scope get _narrowest => _can(_Scope.session)
      ? _Scope.session
      : _can(_Scope.host)
          ? _Scope.host
          : _Scope.all;

  @override
  void initState() {
    super.initState();
    _scope = _narrowest;
    widget.history.refresh();
  }

  @override
  void didUpdateWidget(InputHistoryList old) {
    super.didUpdateWidget(old);
    if (!_can(_scope)) _scope = _narrowest;
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  String _when(DateTime ts) {
    final now = widget.clock(), t = ts.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    return t.year == now.year && t.month == now.month && t.day == now.day ? hm : '${t.month}月${t.day}日 $hm';
  }

  /// The width of the longest time label in the current text style.
  double _timeWidth(BuildContext context) {
    final p = TextPainter(
      text: TextSpan(text: '12月30日 23:59', style: DefaultTextStyle.of(context).style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final w = p.width.ceilToDouble() + 2;
    p.dispose();
    return w;
  }

  Widget _scopeButton(_Scope s, String label, String key) {
    final VoidCallback? go = _can(s)
        ? () => setState(() {
              _scope = s;
              _limit = historyPage;
            })
        : null;
    return Opacity(
      opacity: go == null ? .4 : 1,
      child: IgnorePointer(
        ignoring: go == null,
        // As wide as its label: a bare TabChip fills the whole Wrap line, three stacked bars.
        child: IntrinsicWidth(child: TabChip(key: Key(key), label: label, selected: _scope == s, onTap: go)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([widget.history, _query]),
      builder: (context, _) {
        final found = widget.history.search(
          _query.text,
          session: _scope == _Scope.session ? widget.session : null,
          host: _scope == _Scope.host ? widget.host : null,
        );
        final shown = found.length > _limit ? found.sublist(0, _limit) : found;
        final timeWidth = _timeWidth(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('history-search'),
              controller: _query,
              onChanged: (_) => _limit = historyPage,
              style: TextStyle(color: t.text),
              decoration: InputDecoration(
                hintText: '搜索输入过的内容',
                prefixIcon: Icon(Icons.search, size: 18, color: t.muted),
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _scopeButton(_Scope.session, '这个会话', 'scope-session'),
                _scopeButton(_Scope.host, '这台主机', 'scope-host'),
                _scopeButton(_Scope.all, '全部', 'scope-all'),
              ],
            ),
            const SizedBox(height: 6),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_query.text.isEmpty ? '还没有输入记录' : '没有匹配的记录', style: TextStyle(color: t.muted)),
              ),
            if (shown.isNotEmpty) Divider(height: 1, thickness: 1, color: t.line),
            for (final e in shown) _HistoryRow(key: Key('history-${e.id}'), entry: e, view: this, timeWidth: timeWidth),
            if (found.length > shown.length)
              Align(
                alignment: Alignment.centerRight,
                child: RappButton.secondary(
                  key: const Key('history-more'),
                  label: '再显示 $historyPage 条',
                  onPressed: () => setState(() => _limit += historyPage),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One entry on one line: time, the first line of the text (+N 行 when there is more), 没发出 for a
/// draft, where it was written (not in 这个会话, where every row has the same), and ⋮ with the actions.
/// A click on the row puts it into the editor; a right-click opens the ⋮ menu where the pointer is.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({super.key, required this.entry, required this.view, required this.timeWidth});
  final InputEntry entry;
  final _InputHistoryListState view;

  /// Wide enough for the longest time (`12月30日 23:59`), so the texts line up.
  final double timeWidth;

  /// The whole text as the tooltip; a very long one is cut.
  static String _tip(String s) => s.length > 600 ? '${s.substring(0, 600)}…' : s;

  Future<void> _menu(BuildContext context, RelativeRect at) async {
    final e = entry, w = view.widget;
    final t = RappTokens.of(context);
    Icon icon(IconData i) => Icon(i, size: 16, color: t.muted);
    final original = e.aiOriginal;
    final pick = await showRappMenu<String>(
      context,
      position: at,
      items: [
        RappMenuItem(
            key: Key('put-${e.id}'),
            value: 'put',
            label: '放进输入框',
            enabled: w.onPut != null,
            lead: icon(Icons.keyboard_return)),
        if (original != null) ...[
          RappMenuItem(
              key: Key('put-original-${e.id}'),
              value: 'put-original',
              label: '原话放进输入框',
              enabled: w.onPut != null,
              lead: icon(Icons.record_voice_over_outlined)),
          RappMenuItem(
              key: Key('copy-original-${e.id}'), value: 'copy-original', label: '复制原话', lead: icon(Icons.copy_all)),
        ],
        RappMenuItem(key: Key('copy-${e.id}'), value: 'copy', label: '复制到本机', lead: icon(Icons.copy)),
        if (e.mine) ...[
          const RappMenuItem.divider(),
          RappMenuItem(key: Key('remove-${e.id}'), value: 'remove', label: '从记录里去掉', lead: icon(Icons.close)),
          const RappMenuItem.caption(label: 'git 历史里还在'),
        ],
      ],
    );
    switch (pick) {
      case 'put':
        w.onPut?.call(e.text);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: e.text));
      case 'put-original':
        w.onPut?.call(original!);
      case 'copy-original':
        await Clipboard.setData(ClipboardData(text: original!));
      case 'remove':
        await w.history.remove(e);
    }
  }

  /// Under the ⋮ button, its right edges lined up with the button's.
  RelativeRect _under(BuildContext button) {
    final box = button.findRenderObject() as RenderBox;
    final overlay = Overlay.of(button).context.findRenderObject() as RenderBox;
    final r = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    return RelativeRect.fromLTRB(r.left, r.bottom, overlay.size.width - r.right, overlay.size.height - r.bottom);
  }

  @override
  Widget build(BuildContext context) {
    final touch = touchPlatform(Theme.of(context).platform);
    // A pointer pauses on the row: the whole text. On touch a long press is the menu instead.
    Widget row = LayoutBuilder(builder: (context, box) {
      // The source takes up to 170 but never more than a third of the row; in a narrow panel (the 资源
      // tab of a small window) it goes, so the text keeps its room.
      final third = box.maxWidth / 3;
      final sourceWidth = box.maxWidth < 400 ? 0.0 : (third < 170 ? third : 170.0);
      // Keep a consistent time column, but leave space for multiline drafts'
      // line count and unsent badge in the narrow resource panel.
      return _line(context, sourceWidth, timeWidth < third ? timeWidth : third);
    });
    if (!touch) row = Tooltip(message: _tip(entry.text), waitDuration: const Duration(milliseconds: 600), child: row);
    return row;
  }

  Widget _line(BuildContext context, double sourceWidth, double stampWidth) {
    final t = RappTokens.of(context);
    final e = entry, w = view.widget;
    final touch = touchPlatform(Theme.of(context).platform);
    final title = e.windowTitle;
    final where = [e.hostName, e.appName, if (title != null && title.isNotEmpty) title].join(' · ');
    final lines = e.text.split('\n');
    final muted = TextStyle(color: t.muted);
    final small = TextStyle(color: t.muted, fontSize: t.textSize - 1);
    final put = w.onPut;
    return InkWell(
      onTap: put == null ? null : () => put(e.text),
      onSecondaryTapUp: (d) => _menu(context, menuAt(context, d.globalPosition)),
      onLongPress: touch ? () => _menu(context, _under(context)) : null,
      hoverColor: t.tint,
      child: Container(
        height: controlHeightOf(context),
        padding: const EdgeInsets.only(left: 8),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.line.withValues(alpha: .55)))),
        child: Row(
          children: [
            SizedBox(
              width: stampWidth,
              child: Text(view._when(e.ts), maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(lines.first, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text)),
                  ),
                  if (lines.length > 1) ...[const SizedBox(width: 6), Text('+${lines.length - 1} 行', style: small)],
                ],
              ),
            ),
            // The text is the AI's; the heard one is in the ⋮ menu.
            if (e.aiOriginal != null) ...[
              const SizedBox(width: 8),
              Container(
                key: Key('ai-${e.id}'),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(border: Border.all(color: t.muted), borderRadius: BorderRadius.circular(t.r)),
                child: Text('AI', style: TextStyle(color: t.on, fontSize: t.textSize - 2)),
              ),
            ],
            if (e.kind == 'draft') ...[
              const SizedBox(width: 8),
              Container(
                key: Key('draft-${e.id}'),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(border: Border.all(color: t.muted), borderRadius: BorderRadius.circular(t.r)),
                child: Text('没发出', style: TextStyle(color: t.on, fontSize: t.textSize - 2)),
              ),
            ],
            if (view._scope != _Scope.session && sourceWidth > 0) ...[
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: sourceWidth),
                child: Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
              ),
            ],
            const SizedBox(width: 4),
            Builder(
              builder: (button) => SizedBox(
                width: 36,
                height: 36,
                child: InkResponse(
                  key: Key('more-${e.id}'),
                  radius: 18,
                  onTap: () => _menu(button, _under(button)),
                  child: Semantics(
                    button: true,
                    label: '更多操作',
                    child: Icon(Icons.more_vert, size: 18, color: t.muted),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
