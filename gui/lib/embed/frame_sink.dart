import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';

/// 一帧画面怎么上屏。现在只有「整帧做成 ui.Image」一种（ImageFrameSink），丙落地时加第二种。
abstract class FrameSink {
  Future<ui.Image> decode(Uint8List bgra, int width, int height);
  void retire(ui.Image? image); // 下一帧画完后再释放
}

class ImageFrameSink implements FrameSink {
  const ImageFrameSink();

  @override
  Future<ui.Image> decode(Uint8List bgra, int width, int height) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bgra);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.bgra8888,
    );
    ui.Codec? codec;
    try {
      codec = await descriptor.instantiateCodec();
      return (await codec.getNextFrame()).image;
    } finally {
      codec?.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  @override
  void retire(ui.Image? image) {
    if (image == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) => image.dispose());
    SchedulerBinding.instance.scheduleFrame();
  }
}
