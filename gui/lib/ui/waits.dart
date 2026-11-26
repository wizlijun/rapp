import 'dart:async';

import 'package:flutter/foundation.dart';

/// One slow thing being waited for: what it is (「正在新建终端…」), on what, since when.
class WaitItem {
  WaitItem._(this.what, this.detail, this.started);
  final String what;
  final String? detail;
  final DateTime started;
  bool _visible = false;
  Timer? _timer;
}

/// How the last slow thing that failed ended: its words, and whether the device is asking for permission.
class WaitOutcome {
  const WaitOutcome(this.text, {this.asks = false});
  final String text;
  final bool asks;
}

/// The slow things the app is waiting for, which the wait card shows. One waits only [showAfter] before it shows
/// (a quick one never flashes); a failure's words stay [failFor], a permission ask's [askFor].
class Waits extends ChangeNotifier {
  Waits({
    this.showAfter = const Duration(milliseconds: 300),
    this.failFor = const Duration(seconds: 4),
    this.askFor = const Duration(seconds: 8),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration showAfter, failFor, askFor;
  final DateTime Function() _now;

  /// In the order they started.
  final _items = <WaitItem>[];
  WaitOutcome? _outcome;
  Timer? _outcomeTimer;
  bool _disposed = false;

  /// The ones waited for past [showAfter], oldest first.
  List<WaitItem> get shown => [for (final i in _items) if (i._visible) i];

  WaitOutcome? get outcome => _outcome;

  /// The line under the oldest shown one about the rest: 还有 N 个排队 when they are all the same kind, else
  /// 另有 N 件在等. With nothing shown but an outcome up, it speaks of everything still waiting.
  String? get moreLine {
    final first = shown.firstOrNull ?? (_outcome != null ? _items.firstOrNull : null);
    if (first == null) return null;
    final rest = [for (final i in _items) if (!identical(i, first)) i];
    if (rest.isEmpty) return null;
    return rest.every((i) => i.what == first.what) ? '还有 ${rest.length} 个排队' : '另有 ${rest.length} 件在等';
  }

  /// Waits for [f] (called right away) under [what]. A failure shows [words] of it (else the error) and is thrown
  /// on; [asks] says whether it is a permission prompt on the device.
  Future<T> run<T>(String what, Future<T> Function() f,
      {String? detail, String Function(Object e)? words, bool Function(Object e)? asks}) async {
    final item = WaitItem._(what, detail, _now());
    _items.add(item);
    item._timer = Timer(showAfter, () {
      item._visible = true;
      _notify();
    });
    try {
      return await f();
    } catch (e) {
      _show(WaitOutcome(words?.call(e) ?? '$e', asks: asks?.call(e) ?? false));
      rethrow;
    } finally {
      item._timer?.cancel();
      _items.remove(item);
      _notify();
    }
  }

  void _show(WaitOutcome o) {
    if (_disposed) return;
    _outcome = o;
    _outcomeTimer?.cancel();
    _outcomeTimer = Timer(o.asks ? askFor : failFor, () {
      _outcome = null;
      _notify();
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _outcomeTimer?.cancel();
    for (final i in _items) {
      i._timer?.cancel();
    }
    super.dispose();
  }
}
