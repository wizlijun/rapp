// The 「不锁屏」 card (no-lock spec §7): one switch per computer, under its 余力 row in the overview and under its
// title on the phone's 设备 page. It shows only when the device's load carries `no_lock` (it can do it).
import 'dart:async';

import 'package:flutter/material.dart';

import '../load_model.dart';
import 'controls.dart';
import 'tokens.dart';

/// How long a value the device took stays on the switch while its snapshots still say otherwise.
const noLockPendingFor = Duration(seconds: 15);

class NoLockCard extends StatefulWidget {
  const NoLockCard({
    super.key,
    required this.id,
    required this.load,
    required this.mac,
    required this.onSet,
    required this.say,
    this.margin = EdgeInsets.zero,
  });

  /// The device id, or `local`, for the keys.
  final String id;
  final DeviceLoad? load;

  /// The device is a Mac: the lid line.
  final bool mac;

  /// Asks the device; a refusal or failure is thrown.
  final Future<void> Function(bool on) onSet;
  final void Function(String words) say;

  /// Around the card when it shows; nothing takes room when it does not.
  final EdgeInsetsGeometry margin;

  @override
  State<NoLockCard> createState() => _NoLockCardState();
}

class _NoLockCardState extends State<NoLockCard> {
  /// A request is in flight: the switch keeps its value and takes no taps.
  bool _busy = false;

  /// What the device took, shown until a snapshot says the same, or [noLockPendingFor] passes without one.
  bool? _pending;
  Timer? _pendingTimer;

  @override
  void didUpdateWidget(NoLockCard old) {
    super.didUpdateWidget(old);
    // Reused for another device (a list that changed): nothing of the last one's carries over.
    if (old.id != widget.id) {
      _dropPending();
      _busy = false;
      return;
    }
    if (_pending != null && widget.load?.noLock == _pending) _dropPending();
  }

  @override
  void dispose() {
    _pendingTimer?.cancel();
    super.dispose();
  }

  void _dropPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pending = null;
  }

  Future<void> _set(bool on) async {
    final id = widget.id;
    setState(() => _busy = true);
    try {
      await widget.onSet(on);
      if (!mounted || widget.id != id) return;
      _dropPending();
      if (widget.load?.noLock != on) {
        _pending = on;
        _pendingTimer = Timer(noLockPendingFor, () {
          if (mounted) setState(_dropPending);
        });
      }
    } catch (e) {
      widget.say('$e'.contains('not supported') ? '这台设备不能改它的设置' : '失败：$e');
    } finally {
      if (mounted && widget.id == id) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final load = widget.load;
    final on = load?.noLock;
    if (load == null || on == null) return const SizedBox.shrink();
    final t = RappTokens.of(context);
    final base = DefaultTextStyle.of(context).style;
    Text line(String words, Color colour) => Text(words, style: base.copyWith(color: colour));
    // The words say what the device does now, not what the switch was just asked.
    final lines = !on
        ? [line('没人连着时，会按系统设置熄屏、锁屏', t.muted)]
        : load.noLockHeld
            ? [line('一直亮着，不会自动锁屏', t.muted), if (widget.mac) line('合上笔记本盖子仍会睡眠', t.muted)]
            : [line('没能保持唤醒，正在重试', t.warn)];
    return Padding(
      padding: widget.margin,
      child: Container(
        key: Key('no-lock-card-${widget.id}'),
        decoration: t.panelBox(border: t.line),
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          RappSwitchRow(
            switchKey: Key('no-lock-switch-${widget.id}'),
            label: '不锁屏',
            value: _pending ?? on,
            onChanged: _busy ? null : _set,
          ),
          // The row's own note is always muted; these can be the warn colour, so they sit under it.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: lines),
          ),
        ]),
      ),
    );
  }
}
