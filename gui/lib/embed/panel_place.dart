// Where the open writing panel is on the stage, for iOS's voice button standing above it (the panel floats and
// follows the soft keyboard; the button has to follow the panel).
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'remote_session.dart';

final _places = Expando<ValueNotifier<Rect?>>();

/// Where [s]'s open panel is, in the stage's coordinates (the [StageMark] box, which fills the stage); null while
/// none is laid out.
ValueNotifier<Rect?> panelPlaceOf(RemoteSession s) => _places[s] ??= ValueNotifier(null);

/// Marks the box [PanelPlace] measures from: the panel layer, which fills the stage.
class StageMark extends SingleChildRenderObjectWidget {
  const StageMark({super.key, required super.child});

  @override
  RenderProxyBox createRenderObject(BuildContext context) => _RenderStageMark();
}

class _RenderStageMark extends RenderProxyBox {}

/// Tells [place] where its child is inside the nearest [StageMark] after each paint, and null once it goes. The
/// news lands after the frame, so a listener follows one frame behind.
class PanelPlace extends SingleChildRenderObjectWidget {
  const PanelPlace({super.key, required this.place, required super.child});

  final ValueNotifier<Rect?> place;

  @override
  RenderProxyBox createRenderObject(BuildContext context) => _RenderPanelPlace(place);

  @override
  void updateRenderObject(BuildContext context, RenderProxyBox renderObject) =>
      (renderObject as _RenderPanelPlace).place = place;
}

class _RenderPanelPlace extends RenderProxyBox {
  _RenderPanelPlace(this.place);

  ValueNotifier<Rect?> place;

  void _tell(Rect? r) {
    if (place.value == r) return;
    final p = place;
    SchedulerBinding.instance.addPostFrameCallback((_) => p.value = r);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    RenderObject? a = parent;
    while (a != null && a is! _RenderStageMark) {
      a = a.parent;
    }
    if (a is RenderBox) _tell(localToGlobal(Offset.zero, ancestor: a) & size);
  }

  @override
  void detach() {
    _tell(null);
    super.detach();
  }
}
