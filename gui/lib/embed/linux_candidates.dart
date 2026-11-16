// Linux keeps the normal Flutter TextField/IME. This surface only presents the
// existing SumiCandidates1 snapshot and acknowledges frames it actually paints.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class LinuxCandidate {
  const LinuxCandidate(this.index, this.label, this.text);
  final int index;
  final String label, text;
}

class LinuxCandidateSnapshot {
  const LinuxCandidateSnapshot(this.token, this.serial, this.rows, this.cursor, this.previous, this.next);
  final String token, serial;
  final List<LinuxCandidate> rows;
  final int cursor;
  final bool previous, next;

  static LinuxCandidateSnapshot? parse(Map<Object?, Object?> value) {
    final token = value['token'], serial = value['serial'], rows = value['rows'], cursor = value['cursor'];
    if (token is! String ||
        token.isEmpty ||
        serial is! String ||
        rows is! List ||
        rows.length > 512 ||
        cursor is! int) {
      return null;
    }
    final number = BigInt.tryParse(serial);
    if (number == null || number.isNegative || number > BigInt.parse('18446744073709551615')) return null;
    final result = <LinuxCandidate>[];
    final indices = <int>{};
    var size = 0;
    for (final row in rows) {
      if (row is! Map) return null;
      final index = row['index'], label = row['label'], text = row['text'];
      if (index is! int || index < 0 || !indices.add(index) || label is! String || text is! String) return null;
      size += label.length + text.length;
      if (label.length > 32768 || text.length > 32768 || size > 256 * 1024) return null;
      result.add(LinuxCandidate(index, label, text));
    }
    return LinuxCandidateSnapshot(token, serial, result, cursor, value['previous'] == true, value['next'] == true);
  }
}

// One method-channel handler routes snapshots to exact mounted editors. Native
// GTK focus alone cannot distinguish Flutter fields sharing one IM context.
class _Bridge {
  static const channel = MethodChannel('rapp/linux_candidates');
  static final editors = <String, _LinuxCandidatesSurfaceState>{};
  static int sequence = 0;
  static void register(_LinuxCandidatesSurfaceState state) {
    if (editors.isEmpty) {
      channel.setMethodCallHandler((call) async {
        if (call.method != 'candidates' || call.arguments is! Map) return;
        final args = (call.arguments as Map).cast<Object?, Object?>();
        editors[args['editor']]?.receive(args);
      });
    }
    editors[state.id] = state;
  }
}

/// A transparent, single-row candidate area with local pagination. The child is
/// still the ordinary editor and owns all preedit, commit, selection and undo.
class LinuxCandidatesSurface extends StatefulWidget {
  const LinuxCandidatesSurface({
    super.key,
    required this.focus,
    required this.controller,
    required this.style,
    required this.maxHeight,
    required this.child,
  });
  final FocusNode focus;
  final TextEditingController controller;
  final TextStyle style;
  final double maxHeight;
  final Widget child;
  @override
  State<LinuxCandidatesSurface> createState() => _LinuxCandidatesSurfaceState();
}

class _LinuxCandidatesSurfaceState extends State<LinuxCandidatesSurface> with WidgetsBindingObserver {
  final id = 'composer-${++_Bridge.sequence}';
  int epoch = 0;
  bool focused = false, capacity = false, reserved = false, live = true, queued = false;
  bool frameReady = false, renderEnabled = true;
  Timer? heartbeat;
  LinuxCandidateSnapshot? snapshot;
  int page = 0;
  String? pagedSnapshot;
  String? consumed;

  bool get composing => widget.controller.value.composing.isValid && !widget.controller.value.composing.isCollapsed;
  bool get eligible => focused && capacity && live && frameReady && renderEnabled;
  Future<void> invoke(String method, [Map<String, Object?> extra = const {}]) async {
    try {
      await _Bridge.channel.invokeMethod<void>(method, {'editor': id, 'epoch': epoch, ...extra});
    } on PlatformException {
      /* Missing/failed bridge keeps the system IME. */
    } on MissingPluginException {
      /* Other runners and widget tests. */
    }
  }

  void sendState() {
    if (!mounted) return;
    unawaited(invoke('state', {'active': eligible, 'capacity': capacity, 'composing': composing}));
  }

  @override
  void initState() {
    super.initState();
    _Bridge.register(this);
    WidgetsBinding.instance.addObserver(this);
    widget.focus.addListener(changed);
    widget.controller.addListener(changed);
    focused = widget.focus.hasFocus;
    // The native lease expires if Dart stops delivering this heartbeat, including
    // a renderer freeze after a previously acknowledged candidate frame.
    heartbeat = Timer.periodic(const Duration(milliseconds: 300), (_) => sendState());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    if (renderEnabled != enabled) {
      renderEnabled = enabled;
      if (!enabled) reset();
      sendState();
    }
  }

  @override
  void didUpdateWidget(LinuxCandidatesSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focus != widget.focus || oldWidget.controller != widget.controller) {
      reset();
      focused = widget.focus.hasFocus;
    }
    if (oldWidget.focus != widget.focus) {
      oldWidget.focus.removeListener(changed);
      widget.focus.addListener(changed);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(changed);
      widget.controller.addListener(changed);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    live = state == AppLifecycleState.resumed;
    if (!live) setState(reset);
    sendState();
  }

  void reset() {
    epoch++;
    snapshot = null;
    consumed = null;
    reserved = false;
    page = 0;
  }

  void changed() {
    if (!mounted) return;
    final next = widget.focus.hasFocus;
    setState(() {
      if (next != focused) {
        reset();
        focused = next;
      }
      if (widget.controller.text.isEmpty && !composing) reserved = false;
    });
    sendState();
  }

  void receive(Map<Object?, Object?> args) {
    if (!mounted || !eligible || args['epoch'] != epoch) return;
    final next = LinuxCandidateSnapshot.parse(args);
    if (next == null) {
      setState(reset);
      sendState();
      return;
    }
    final old = snapshot;
    if (old != null && old.token == next.token && BigInt.parse(next.serial) < BigInt.parse(old.serial)) return;
    setState(() {
      snapshot = next;
      page = 0;
      consumed = null;
      if (next.rows.isNotEmpty) reserved = true;
    });
  }

  void capacityAfterFrame(bool next) {
    if (queued) return;
    queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      queued = false;
      if (!mounted) return;
      frameReady = true;
      if (capacity != next) {
        setState(() {
          capacity = next;
          if (!next) reset();
        });
      }
      sendState();
    });
  }

  void action(String method, [Map<String, Object?> extra = const {}]) {
    final current = snapshot;
    if (!eligible || current == null || consumed == '${current.token}/${current.serial}') return;
    consumed = '${current.token}/${current.serial}';
    unawaited(invoke(method, {'token': current.token, 'serial': current.serial, ...extra}));
  }

  @override
  void dispose() {
    heartbeat?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.focus.removeListener(changed);
    widget.controller.removeListener(changed);
    _Bridge.editors.remove(id);
    unawaited(invoke('dispose'));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Resolve inheritance once: measuring a partial style while Text.rich merges
    // the ambient style can make every allocated candidate narrower than its text.
    final textStyle = DefaultTextStyle.of(
      context,
    ).style.merge(widget.style).copyWith(inherit: false, shadows: const []);
    final painter = TextPainter(
      text: TextSpan(text: '字Mg', style: textStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final rowHeight = painter.height;
    double measure(String text) => (TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout()).width;
    final navigation = math.max(rowHeight * 2.5, measure('‹  ›') + measure('  '));
    final minimumWidth = navigation + measure('1 中…');
    final rowSpace = rowHeight + 13;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Preflight enough room for one editable line and one candidate plus both
        // paging controls. Registration occurs only after this layout is rendered.
        final maxHeight = math.min(widget.maxHeight, constraints.maxHeight);
        final room =
            constraints.maxWidth.isFinite &&
            constraints.maxWidth >= minimumWidth &&
            maxHeight >= rowSpace + rowHeight + 26;
        capacityAfterFrame(room);
        final show = reserved && room && focused && live && renderEnabled;
        final current = snapshot;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: (maxHeight - (show ? rowSpace : 0)).clamp(0, double.infinity)),
              child: widget.child,
            ),
            if (show)
              SizedBox(
                height: rowSpace,
                child: current == null || current.rows.isEmpty
                    ? null
                    : _row(context, current, constraints.maxWidth, rowHeight, navigation, textStyle),
              ),
          ],
        );
      },
    );
  }

  Widget _row(
    BuildContext context,
    LinuxCandidateSnapshot current,
    double width,
    double height,
    double navigation,
    TextStyle style,
  ) {
    final muted = style.copyWith(color: (style.color ?? const Color(0xff888888)).withValues(alpha: .65));
    final available = width - navigation;
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    double measure(String text, TextStyle style) => (TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout()).width;
    final gap = math.max(2.0, measure('  ', style));
    TextSpan span(LinuxCandidate candidate) => TextSpan(
      style: style,
      children: [
        TextSpan(text: '${candidate.label} ', style: muted),
        TextSpan(
          text: candidate.text,
          style: style.copyWith(
            decoration: candidate.index == current.cursor ? TextDecoration.underline : TextDecoration.none,
          ),
        ),
      ],
    );
    double natural(LinuxCandidate candidate) =>
        (TextPainter(
          text: span(candidate),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          locale: locale,
        )..layout()).width.ceilToDouble() +
        gap;
    final pages = <List<LinuxCandidate>>[];
    var row = <LinuxCandidate>[], used = 0.0;
    for (final candidate in current.rows) {
      final span = natural(candidate);
      if (row.isNotEmpty && used + span > available) {
        pages.add(row);
        row = [];
        used = 0;
      }
      row.add(candidate);
      used += span.clamp(0, available);
    }
    if (row.isNotEmpty) pages.add(row);
    final key = '${current.token}/${current.serial}/$available/$height/${style.hashCode}';
    if (pagedSnapshot != key) {
      pagedSnapshot = key;
      final selected = pages.indexWhere((rows) => rows.any((r) => r.index == current.cursor));
      page = selected < 0 ? 0 : selected;
    }
    page = page.clamp(0, pages.length - 1);
    final shown = pages[page];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && eligible && identical(snapshot, current)) {
        unawaited(invoke('rendered', {'token': current.token, 'serial': current.serial}));
      }
    });
    Widget arrow(bool next) {
      final local = next ? page + 1 < pages.length : page > 0;
      final enabled = local || (next ? current.next : current.previous);
      return SizedBox(
        width: navigation / 2,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: !enabled
              ? null
              : () {
                  if (local) {
                    setState(() => page += next ? 1 : -1);
                  } else {
                    action('page', {'next': next});
                  }
                },
          child: Semantics(
            button: true,
            label: next ? '下一页候选' : '上一页候选',
            enabled: enabled,
            child: Text(
              next ? '›' : '‹',
              textAlign: TextAlign.center,
              style: enabled ? style : muted.copyWith(color: Colors.transparent),
            ),
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  for (final candidate in shown)
                    SizedBox(
                      width: math.min(available, natural(candidate)),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => action('select', {'index': candidate.index}),
                        child: Semantics(
                          button: true,
                          label: candidate.text,
                          child: Padding(
                            padding: EdgeInsets.only(right: gap),
                            child: Text.rich(
                              span(candidate),
                              style: style,
                              textDirection: TextDirection.ltr,
                              textScaler: scaler,
                              locale: locale,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            arrow(false),
            arrow(true),
          ],
        ),
      ),
    );
  }
}
