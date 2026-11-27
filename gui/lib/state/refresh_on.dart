// Looks again for the center service (rapp-center) as soon as what finding it depends on changes, instead of at the next 60 s look.
import 'package:flutter/foundation.dart';

import 'state_sync.dart';

/// On each change of [watch] (compared by identity) to something other than `false`, while [sync] found nothing
/// (`none`), calls `sync.refresh()`. A `bool` watch fires on false to true only.
void refreshStateOn(Listenable source, Object Function() watch, StateSync sync) {
  var last = watch();
  source.addListener(() {
    final now = watch();
    if (identical(now, last)) return;
    last = now;
    if (now != false && sync.status == StateStatus.none) sync.refresh();
  });
}
