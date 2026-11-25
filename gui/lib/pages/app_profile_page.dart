// The form for one app's settings: stream, after-send, composer and window rules.
// Fields still unset show the built-in / default value in grey; changing one writes it.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../embed/app_profile.dart';
import '../embed/app_state.dart';
import '../embed/session_port.dart';
import '../embed/state_rules.dart';
import '../ui/app_profile_store.dart';
import '../ui/controls.dart';
import '../ui/tokens.dart';

/// What the live session of this app runs on: the pack sent to it, its latest report, and the unreadable files of 我的.
class RulesView {
  const RulesView({this.chosen, this.state, this.errors = const []});
  final ChosenRules? chosen;
  final AppState? state;
  final List<String> errors;
}

Future<void> openAppProfilePage(BuildContext context, AppProfileStore store,
        {String? appId, String appName = '', RulesView? rules}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AppProfilePage(store: store, appId: appId, appName: appName, rules: rules)),
    );

const _modeLabels = {'duogray': '双色·灰度', 'duocolor': '双色·彩色', 'color16': '高彩'};
const _densityLabels = {'saver1x': '省流 1x', 'adaptive': '自适应', 'original': '原画'};
const _kindLabels = {
  null: '任意种类',
  WindowKind.normal: '普通窗口',
  WindowKind.dialog: '对话框',
  WindowKind.floating: '浮动窗口',
  WindowKind.sheet: '附着对话框',
  WindowKind.popover: '弹出框',
  WindowKind.menu: '菜单',
  WindowKind.tooltip: '提示条',
};
const _actionLabels = {RuleAction.hide: '隐藏', RuleAction.noComposer: '不要输入区'};

class AppProfilePage extends StatefulWidget {
  const AppProfilePage({super.key, required this.store, this.appId, this.appName = '', this.rules});

  final AppProfileStore store;

  /// Null when no session of this app is open.
  final RulesView? rules;
  final String? appId;
  final String appName;

  @override
  State<AppProfilePage> createState() => _AppProfilePageState();
}

class _AppProfilePageState extends State<AppProfilePage> {
  late final AppProfile? _orig;
  late final AppProfile _draft;
  late final AppProfile? _builtin;
  late final ResolvedProfile _base;
  late final List<String> _defaultIds;
  late final TextEditingController _name, _ids, _pack;
  late List<Key> _keys;
  int _nextKey = 0;
  bool _idsMissing = false;

  /// 指定 is picked (its box shows); the draft holds the name only once one is typed.
  bool _packMode = false;

  @override
  void initState() {
    super.initState();
    final id = widget.appId;
    final s = widget.store;
    _orig = id == null ? null : s.mineFor(id);
    _builtin = id == null ? null : s.builtinFor(id);
    _defaultIds = [...(_builtin?.ids ?? (id == null ? const <String>[] : [id]))];
    _draft = _orig?.copy() ?? AppProfile(ids: [..._defaultIds]);
    _base = resolveProfile(id ?? '', mine: const [], builtin: s.builtin);
    _name = TextEditingController(text: _draft.name ?? _base.name ?? '');
    _ids = TextEditingController(text: _draft.ids.join(', '));
    final sr = _draft.stateRules;
    _pack = TextEditingController(text: sr == null || sr == 'off' ? '' : sr);
    _packMode = sr != null && sr != 'off';
    _keys = [for (var i = 0; i < _rules.length; i++) _newKey()];
  }

  @override
  void dispose() {
    _name.dispose();
    _ids.dispose();
    _pack.dispose();
    super.dispose();
  }

  Key _newKey() => ValueKey(_nextKey++);

  List<WindowRule> get _rules => _draft.windows ?? _base.windows;

  /// Copies the shown rules into the draft (the first edit) and returns the editable list.
  List<WindowRule> _editRules() => _draft.windows ??= [..._base.windows];

  void _set(VoidCallback f) => setState(f);

  String get _title {
    final id = widget.appId;
    if (id == null) return '新建 app 配置';
    final n = _draft.name ?? _base.name ?? (widget.appName.isEmpty ? id : widget.appName);
    return 'app 配置 · $n';
  }

  List<String> _parseIds() => [
        for (final p in _ids.text.split(RegExp('[,，]')))
          if (p.trim().isNotEmpty) p.trim(),
      ];

  bool get _untouched =>
      _orig == null &&
      _draft.name == null &&
      _draft.mode == null &&
      _draft.density == null &&
      _draft.fps == null &&
      _draft.afterSend == null &&
      _draft.composer == null &&
      _draft.recordInput == null &&
      _draft.typeToCompose == null &&
      _draft.focusPane == null &&
      _draft.rime == null &&
      _draft.phrases == null &&
      _draft.input == null &&
      _draft.windows == null &&
      _draft.stateRules == null &&
      _draft.tested == null &&
      _sameIds(_draft.ids, _defaultIds);

  static bool _sameIds(List<String> a, List<String> b) =>
      a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((e) => e);

  void _save() {
    if (_builtin == null) _draft.ids = _parseIds();
    if (_draft.ids.isEmpty) {
      setState(() => _idsMissing = true);
      return;
    }
    if (!_untouched) {
      if (_builtin == null && _orig == null && _draft.name == null && widget.appName.isNotEmpty) {
        _draft.name = widget.appName;
      }
      widget.store.put(_draft, replacing: _orig);
    }
    Navigator.of(context).pop();
  }

  static const _healthWords = {'ok': '正常', 'switched': '自动换了变体', 'unfit': '对不上', 'invalid': '规则读不了'};

  List<Widget> _rulesSection(RappTokens t) {
    final d = _draft;
    final v = widget.rules;
    final mode = _packMode ? 'pack' : (d.stateRules == 'off' ? 'off' : 'auto');
    Widget line(String text, {Key? key, bool muted = false}) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(text, key: key, style: TextStyle(color: muted ? t.muted : t.text)));
    final c = v?.chosen, a = v?.state;
    return [
      _label(t, '状态规则'),
      Wrap(spacing: 16, crossAxisAlignment: WrapCrossAlignment.center, children: [
        RappChoice(
            key: const Key('rules-auto'),
            label: '自动',
            selected: mode == 'auto',
            onTap: () => _set(() {
                  _packMode = false;
                  d.stateRules = null;
                })),
        RappChoice(
            key: const Key('rules-off'),
            label: '关',
            selected: mode == 'off',
            onTap: () => _set(() {
                  _packMode = false;
                  d.stateRules = 'off';
                })),
        RappChoice(
            key: const Key('rules-pack'),
            label: '指定',
            selected: mode == 'pack',
            onTap: () => _set(() {
                  _packMode = true;
                  final p = _pack.text.trim();
                  d.stateRules = p.isEmpty ? null : p;
                })),
        if (_packMode)
          SizedBox(
            width: 200,
            child: TextField(
              key: const Key('rules-pack-field'),
              controller: _pack,
              decoration: _deco(t, hint: '包名'),
              onChanged: (x) => _set(() => d.stateRules = x.trim().isEmpty ? null : x.trim()),
            ),
          ),
      ]),
      if (v == null)
        line('会话没开，看不到用的是哪一包', muted: true)
      else ...[
        if (c == null)
          line('用的包：没有', key: const Key('rules-used'), muted: true)
        else ...[
          line('用的包：${c.id} · 修订 ${c.rev} · ${c.layer == RulesLayer.builtin ? '内置' : '我的'}${c.patched ? '（有补丁）' : ''}',
              key: const Key('rules-used')),
          line('验到：验过 ${c.tally.tested} · 见过 ${c.tally.seen} · 有人报过 ${c.tally.reported} · 未验 ${c.tally.untested}'),
        ],
        if (c != null && a != null) ...[
          line('情况：${_healthWords[a.health] ?? '正常'}'),
          if (a.health == 'unfit' || a.health == 'invalid') line('状态规则可能过期', muted: true),
          if (a.appVersion != null && a.appVersion!.isNotEmpty) line('app 版本：${a.appVersion}'),
        ],
        if (v.errors.isNotEmpty) line('“我的”里有 ${v.errors.length} 个文件读不了', muted: true),
      ],
    ];
  }

  Widget _label(RappTokens t, String s) =>
      Padding(padding: const EdgeInsets.only(top: 18, bottom: 6), child: Text(s, style: TextStyle(color: t.text, fontWeight: FontWeight.w600)));

  Widget _dropdown<T>(RappTokens t,
          {Key? key, required T value, required Map<T, String> labels, required bool grey, required ValueChanged<T> onChanged}) =>
      RappDropdown<T>(
        key: key,
        expand: true,
        dim: grey,
        current: value,
        label: Text(labels[value] ?? ''),
        items: [for (final e in labels.entries) RappMenuItem<T>(value: e.key, label: e.value)],
        onSelected: (v) => _set(() => onChanged(v)),
      );

  Widget _field(String label, Widget child, RappTokens t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          SizedBox(width: 56, child: Text(label, style: TextStyle(color: t.text))),
          Expanded(child: child),
        ]),
      );

  InputDecoration _deco(RappTokens t, {String? hint, bool counter = false}) => InputDecoration(
        hintText: hint,
        counterText: counter ? null : '',
      );

  void _editRule(int i, WindowRule r) => _set(() => _editRules()[i] = r);

  void _move(int i, int d) {
    final j = i + d;
    if (j < 0 || j >= _rules.length) return;
    _set(() {
      final l = _editRules();
      final r = l.removeAt(i);
      l.insert(j, r);
      final k = _keys.removeAt(i);
      _keys.insert(j, k);
    });
  }

  void _delete(int i) => _set(() {
        _editRules().removeAt(i);
        _keys.removeAt(i);
      });

  void _add() => _set(() {
        _editRules().add(const WindowRule(action: RuleAction.hide));
        _keys.add(_newKey());
      });

  Widget _ruleRow(RappTokens t, int i, WindowRule r, bool grey) {
    final color = grey ? t.muted : t.text;
    final anyKind = r.kind == null && (r.title == null || r.title!.isEmpty);
    final waiting = r.action == RuleAction.hide && (r.kind == WindowKind.dialog || r.kind == WindowKind.sheet);
    return Padding(
      key: _keys[i],
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 140,
            child: _dropdown<WindowKind?>(t,
                key: Key('rule-kind-$i'),
                value: r.kind,
                labels: _kindLabels,
                grey: grey,
                onChanged: (v) => _editRule(i, WindowRule(kind: v, title: r.title, child: r.child, action: r.action))),
          ),
          SizedBox(
            width: 240,
            child: _RuleTitle(
              key: Key('rule-title-$i'),
              initial: r.title ?? '',
              color: color,
              decoration: _deco(t, hint: '标题，* 配任意字；空着就不看标题'),
              onChanged: (v) => _editRule(
                  i, WindowRule(kind: r.kind, title: v.isEmpty ? null : v, child: r.child, action: r.action)),
            ),
          ),
          SizedBox(
            width: 150,
            child: _dropdown<RuleAction>(t,
                key: Key('rule-action-$i'),
                value: r.action,
                labels: _actionLabels,
                grey: grey,
                onChanged: (v) => _editRule(i, WindowRule(kind: r.kind, title: r.title, child: r.child, action: v))),
          ),
          RappButton.secondary(label: '上移', onPressed: () => _move(i, -1)),
          RappButton.secondary(label: '下移', onPressed: () => _move(i, 1)),
          RappButton.secondary(label: '删除', onPressed: () => _delete(i)),
        ]),
        if (anyKind)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text('这条会作用于这个 app 的所有子窗口', style: TextStyle(color: t.muted))),
        if (waiting)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text('它可能在等你回应', style: TextStyle(color: t.muted))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final d = _draft, b = _base;
    final afterSend = d.afterSend ?? b.afterSend;
    final composer = d.composer ?? b.composer;
    final recordInput = d.recordInput ?? b.recordInput;
    final typeToCompose = d.typeToCompose ?? b.typeToCompose;
    final focusPane = d.focusPane ?? b.focusPane;
    final rime = d.rime ?? b.rime;
    final phrases = d.phrases ?? b.phrases;
    final rules = _rules;
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.bg,
        foregroundColor: t.text,
        title: Row(children: [
          Flexible(child: Text(_title, style: TextStyle(color: t.text), overflow: TextOverflow.ellipsis)),
          if (_builtin != null && !b.tested) ...[
            const SizedBox(width: 10),
            Text('未实测', style: TextStyle(color: t.muted)),
          ],
        ]),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            key: const Key('name-field'),
            controller: _name,
            maxLength: 40,
            style: TextStyle(color: d.name == null ? t.muted : t.text),
            decoration: _deco(t, hint: widget.appName, counter: true).copyWith(labelText: '名字'),
            onChanged: (v) => _set(() => d.name = v.trim().isEmpty ? null : v),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('ids-field'),
            controller: _ids,
            readOnly: _builtin != null,
            style: TextStyle(color: _builtin != null ? t.muted : t.text),
            decoration: _deco(t).copyWith(labelText: '标识（用逗号分开）'),
            onChanged: (_) => setState(() => _idsMissing = false),
          ),
          if (_idsMissing)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('至少写一个标识', style: TextStyle(color: Theme.of(context).colorScheme.error))),
          _label(t, '画面'),
          _field(
              '档位',
              _dropdown<String>(t,
                  key: const Key('mode-dd'),
                  value: d.mode ?? b.stream.mode,
                  labels: _modeLabels,
                  grey: d.mode == null,
                  onChanged: (v) => d.mode = v),
              t),
          _field(
              '密度',
              _dropdown<String>(t,
                  key: const Key('density-dd'),
                  value: d.density ?? b.stream.density,
                  labels: _densityLabels,
                  grey: d.density == null,
                  onChanged: (v) => d.density = v),
              t),
          _field(
              '帧率',
              _dropdown<int>(t,
                  key: const Key('fps-dd'),
                  value: d.fps ?? b.stream.fps,
                  labels: {for (final f in const [1, 5, 15, 30]) f: '$f fps'},
                  grey: d.fps == null,
                  onChanged: (v) => d.fps = v),
              t),
          RappSwitchRow(
            switchKey: const Key('focus-pane-switch'),
            label: '智能时按焦点分区',
            value: focusPane,
            dim: d.focusPane == null,
            onChanged: (v) => _set(() => d.focusPane = v),
          ),
          _label(t, '发送后'),
          RappChoice(
            label: '只贴，不按回车',
            selected: afterSend == AfterSend.none,
            dim: d.afterSend == null,
            onTap: () => _set(() => _draft.afterSend = AfterSend.none),
          ),
          RappChoice(
            label: '贴完按回车并收起输入板',
            selected: afterSend == AfterSend.pressReturn,
            dim: d.afterSend == null,
            onTap: () => _set(() => _draft.afterSend = AfterSend.pressReturn),
          ),
          _label(t, '输入区'),
          RappSwitchRow(
            switchKey: const Key('composer-switch'),
            label: '显示「输入」',
            value: composer,
            dim: d.composer == null,
            onChanged: (v) => _set(() => d.composer = v),
          ),
          RappSwitchRow(
            switchKey: const Key('record-input-switch'),
            label: '记下发给这个 app 的话',
            note: '关掉后草稿只存在本机',
            value: recordInput,
            dim: d.recordInput == null,
            onChanged: (v) => _set(() => d.recordInput = v),
          ),
          RappSwitchRow(
            switchKey: const Key('type-to-compose-switch'),
            label: '在画面上按字母键时打开写作面板',
            note: '关掉后字母直接发给这个 app，适合 Figma、游戏、密码管理器',
            value: typeToCompose,
            dim: d.typeToCompose == null,
            onChanged: (v) => _set(() => d.typeToCompose = v),
          ),
          // 常用语 live on the iOS key bar; the field stays harmless in the file elsewhere.
          if (defaultTargetPlatform == TargetPlatform.iOS)
            RappSwitchRow(
              switchKey: const Key('phrases-profile-switch'),
              label: '常用语条',
              note: '按键区上方一排常用的话，点一下就发出并回车',
              value: phrases,
              dim: d.phrases == null,
              onChanged: (v) => _set(() => d.phrases = v),
            ),
          // The built-in input method exists only on iOS; the field stays harmless in the file elsewhere.
          if (defaultTargetPlatform == TargetPlatform.iOS)
            RappSwitchRow(
              switchKey: const Key('rime-profile-switch'),
              label: '接实体键盘时用内置输入法',
              note: '关掉后这个 app 的输入板用系统输入法',
              value: rime,
              dim: d.rime == null,
              onChanged: (v) => _set(() => d.rime = v),
            ),
          Row(children: [
            Expanded(
              child: Text(
                d.input == null
                    ? '输入框位置：没标记（会话的「本机」菜单里「标记输入区」）'
                    : '输入框位置：左起 ${(d.input!.x * 100).round()}%，距${d.input!.fromBottom ? '底' : '顶'} '
                        '${d.input!.dy.round()} 点；发送前先点它',
                key: const Key('input-point'),
                style: TextStyle(color: d.input == null ? t.muted : t.text),
              ),
            ),
            if (d.input != null)
              RappButton.secondary(
                  key: const Key('input-point-clear'), label: '清除', onPressed: () => _set(() => d.input = null)),
          ]),
          Row(children: [
            Expanded(
              child: Text(
                d.composerAt == null
                    ? '写作面板位置：底部居中（默认）'
                    : '写作面板位置：左起 ${(d.composerAt!.x * 100).round()}%，'
                        '距${d.composerAt!.fromBottom ? '底' : '顶'} ${d.composerAt!.dy.round()}',
                key: const Key('composer-at'),
                style: TextStyle(color: d.composerAt == null ? t.muted : t.text),
              ),
            ),
            if (d.composerAt != null)
              RappButton.secondary(
                  key: const Key('composer-at-clear'),
                  label: '回到默认',
                  onPressed: () => _set(() => d.composerAt = null)),
          ]),
          ..._rulesSection(t),
          _label(t, '窗口规则'),
          for (var i = 0; i < rules.length; i++) _ruleRow(t, i, rules[i], d.windows == null),
          Align(alignment: Alignment.centerLeft, child: RappButton.secondary(label: '加一条', onPressed: _add)),
          const SizedBox(height: 24),
          Row(children: [
            RappButton.primary(label: '保存', onPressed: _save),
            const SizedBox(width: 8),
            RappButton.secondary(label: '取消', onPressed: () => Navigator.of(context).pop()),
          ]),
        ]),
      ),
    );
  }
}

/// A title box that owns its controller, so a rule edit does not reset the cursor.
class _RuleTitle extends StatefulWidget {
  const _RuleTitle(
      {super.key, required this.initial, required this.color, required this.decoration, required this.onChanged});
  final String initial;
  final Color color;
  final InputDecoration decoration;
  final ValueChanged<String> onChanged;

  @override
  State<_RuleTitle> createState() => _RuleTitleState();
}

class _RuleTitleState extends State<_RuleTitle> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TextField(controller: _c, style: TextStyle(color: widget.color), decoration: widget.decoration, onChanged: widget.onChanged);
}
