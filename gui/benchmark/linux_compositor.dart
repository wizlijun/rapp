// Build with `flutter build linux --release --target=benchmark/linux_compositor.dart`.
// Exercises the real GTK/Flutter compositor without a service, network or input.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final fps = args.isEmpty ? 30 : int.parse(args.first);
  final tick = ValueNotifier<int>(0);
  var paints = 0;
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: CustomPaint(
        painter: _Pattern(tick, () => paints++),
        child: const SizedBox.expand(),
      ),
    ),
  );
  final timer = Timer.periodic(
    Duration(microseconds: 1000000 ~/ fps),
    (_) => tick.value++,
  );
  Timer(const Duration(seconds: 16), () {
    timer.cancel();
    stdout.writeln(
      'COMPOSITOR_BENCH fps=$fps ticks=${tick.value} paints=$paints',
    );
    exit(0);
  });
}

class _Pattern extends CustomPainter {
  _Pattern(this.tick, this.onPaint) : super(repaint: tick);
  final ValueNotifier<int> tick;
  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff0c1418),
    );
    for (var y = 0.0; y < size.height; y += 40) {
      canvas.drawRect(
        Rect.fromLTWH(30, y, size.width - 60, 20),
        Paint()..color = const Color(0xff198580),
      );
    }
    canvas.drawRect(
      Rect.fromLTWH((tick.value * 7) % (size.width - 100), 100, 100, 100),
      Paint()..color = const Color(0xffffcc33),
    );
  }

  @override
  bool shouldRepaint(_Pattern old) => false;
}
