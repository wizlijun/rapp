// One kind of the 常用语 doc on its settings page (cmd-menu design): the 命令 page lists the StripCmds, the 常用语 page the
// Phrases. Drag to reorder, swipe to delete, tap to edit, ★ for the first row; the other kind keeps its slots
// ([withKind]).
import 'package:flutter/material.dart';

import '../embed/phrases.dart';
import '../embed/strip_cmds.dart';
import '../ui/main_state.dart';
import '../ui/star_button.dart';
import '../ui/tokens.dart';

/// The items of kind [T] in [state]'s 常用语 doc, in list order.
List<T> itemsOf<T extends StripItem>(MainState state) => state.quick.phrases.whereType<T>().toList();

/// Writes [items] back as the whole of kind [T].
void setItemsOf<T extends StripItem>(MainState state, List<T> items) =>
    state.setStripItems(withKind<T>(state.quick.phrases, items));

class StripKindList<T extends StripItem> extends StatelessWidget {
  const StripKindList({
    super.key,
    required this.state,
    required this.rowKey,
    required this.starKey,
    required this.title,
    required this.subtitle,
    required this.onEdit,
  });

  final MainState state;

  /// Key prefixes; the row's index in this kind is appended.
  final String rowKey, starKey;
  final Widget Function(T item, RappTokens t) title;
  final Widget? Function(T item, RappTokens t) subtitle;

  /// Tap on the row at this kind's index.
  final void Function(int i) onEdit;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    final l = itemsOf<T>(state);
    final stars = state.quick.stars;
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorderItem: (from, to) {
        final m = List.of(l);
        m.insert(to, m.removeAt(from));
        setItemsOf<T>(state, m);
      },
      children: [
        for (final (i, p) in l.indexed)
          Dismissible(
            key: ValueKey('$rowKey$i-${refOf(p)}'),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 16),
              color: Colors.red.withValues(alpha: .7),
              child: const Text('删除', style: TextStyle(color: Colors.white)),
            ),
            onDismissed: (_) => state.setStripItems([
              for (final it in state.quick.phrases)
                if (!identical(it, p)) it,
            ]),
            child: ListTile(
              key: Key('$rowKey$i'),
              contentPadding: EdgeInsets.zero,
              title: title(p, t),
              subtitle: subtitle(p, t),
              onTap: () => onEdit(i),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                StarButton(
                  key: Key('$starKey$i'),
                  starred: stars.contains(refOf(p)),
                  onPressed: () => state.toggleStar(refOf(p)),
                ),
                ReorderableDragStartListener(index: i, child: Icon(Icons.drag_handle, color: t.muted)),
              ]),
            ),
          ),
      ],
    );
  }
}
