import 'package:flutter/foundation.dart';

enum RimeState { off, starting, ready, error }

enum RimeDictionary { bundled, user }

class RimeStatus {
  const RimeStatus({this.state = RimeState.off, this.message = '', this.keyboard = false});
  final RimeState state;
  final String message;
  final bool keyboard;

  /// Bad or missing fields fall back to off / '' / false.
  static RimeStatus parse(Object? args) {
    if (args is! Map) return const RimeStatus();
    final state = switch (args['state']) {
      'starting' => RimeState.starting,
      'ready' => RimeState.ready,
      'error' => RimeState.error,
      _ => RimeState.off,
    };
    final message = args['message'];
    return RimeStatus(
      state: state,
      message: message is String ? message : '',
      keyboard: args['keyboard'] == true,
    );
  }
}

@immutable
class RimeCandidate {
  const RimeCandidate(this.index, this.label, this.text);
  final int index;
  final String label, text;
}

@immutable
class RimeMenu {
  const RimeMenu({this.rows = const [], this.cursor = -1, this.previous = false, this.next = false});
  static const empty = RimeMenu();
  final List<RimeCandidate> rows;
  final int cursor;
  final bool previous, next;
}

@immutable
class RimeUpdate {
  const RimeUpdate({
    this.commit = '',
    this.preedit = '',
    this.caret = 0,
    this.input = '',
    this.ascii = false,
    this.menu = RimeMenu.empty,
  });
  final String commit, preedit, input;
  final int caret;
  final bool ascii;
  final RimeMenu menu;

  /// Null when [args] is not a map or a candidate row is malformed.
  static RimeUpdate? parse(Object? args) {
    if (args is! Map) return null;
    String str(String key) => args[key] is String ? args[key] as String : '';
    final preedit = str('preedit');
    final rawCaret = args['caret'];
    final caret = (rawCaret is int ? rawCaret : 0).clamp(0, preedit.length);
    var menu = RimeMenu.empty;
    final rawMenu = args['menu'];
    if (rawMenu is Map) {
      final rows = <RimeCandidate>[];
      final rawRows = rawMenu['rows'];
      if (rawRows != null) {
        if (rawRows is! List) return null;
        for (final row in rawRows) {
          if (row is! Map) return null;
          final index = row['index'], label = row['label'], text = row['text'];
          if (index is! int || label is! String || text is! String) return null;
          rows.add(RimeCandidate(index, label, text));
        }
      }
      final cursor = rawMenu['cursor'];
      menu = RimeMenu(
        rows: rows,
        cursor: cursor is int ? cursor : -1,
        previous: rawMenu['previous'] == true,
        next: rawMenu['next'] == true,
      );
    }
    return RimeUpdate(
      commit: str('commit'),
      preedit: preedit,
      caret: caret,
      input: str('input'),
      ascii: args['ascii'] == true,
      menu: menu,
    );
  }
}
