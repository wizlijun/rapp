// The 「输入历史」 list (spec 2026-11-14-rapp-input-history R4, R5): search over every device's
// input record, three scopes, and per entry 放进输入框 / 复制到本机 / 从记录里去掉.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/controls.dart';
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

  Widget _scopeButton(_Scope s, String label, String key) {
    final VoidCallback? go = _can(s)
        ? () => setState(() {
              _scope = s;
              _limit = historyPage;
            })
        : null;
    return _scope == s
        ? RappButton.primary(key: Key(key), label: label, onPressed: go)
        : RappButton.secondary(key: Key(key), label: label, onPressed: go);
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
                hintStyle: TextStyle(color: t.muted),
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18, color: t.muted),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(t.r)),
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
            for (final e in shown) _HistoryRow(key: Key('history-${e.id}'), entry: e, view: this),
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

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({super.key, required this.entry, required this.view});
  final InputEntry entry;
  final _InputHistoryListState view;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final e = entry, w = view.widget;
    final title = e.windowTitle;
    final where = [e.hostName, e.appName, if (title != null && title.isNotEmpty) title].join(' · ');
    final first = e.text.split('\n').first;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: t.line), borderRadius: BorderRadius.circular(t.r)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(view._when(e.ts), style: TextStyle(color: t.muted)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.muted)),
              ),
              if (e.kind == 'draft')
                Text('没发出', key: Key('draft-${e.id}'), style: TextStyle(color: t.text)),
            ],
          ),
          const SizedBox(height: 2),
          Text(first, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text)),
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              RappButton.secondary(
                key: Key('put-${e.id}'),
                label: '放进输入框',
                onPressed: w.onPut == null ? null : () => w.onPut!(e.text),
              ),
              RappButton.secondary(
                key: Key('copy-${e.id}'),
                label: '复制到本机',
                onPressed: () => Clipboard.setData(ClipboardData(text: e.text)),
              ),
              if (e.mine) ...[
                RappButton.secondary(
                  key: Key('remove-${e.id}'),
                  label: '从记录里去掉',
                  onPressed: () => w.history.remove(e),
                ),
                Text('git 历史里还在', style: TextStyle(color: t.muted)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
