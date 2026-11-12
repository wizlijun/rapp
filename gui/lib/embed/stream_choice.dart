// What the user chose for one session's stream: picture mode, density and frame rate (R11, R18).
class StreamChoice {
  const StreamChoice(this.mode, this.density, this.fps);

  /// `duogray`, `duocolor` or `color16` (the runner's `set_stream` names).
  final String mode;

  /// `saver1x`, `adaptive` or `original`.
  final String density;
  final int fps;

  @override
  bool operator ==(Object other) =>
      other is StreamChoice && other.mode == mode && other.density == density && other.fps == fps;

  @override
  int get hashCode => Object.hash(mode, density, fps);

  StreamChoice copyWith({String? mode, String? density, int? fps}) =>
      StreamChoice(mode ?? this.mode, density ?? this.density, fps ?? this.fps);

  @override
  String toString() => 'StreamChoice($mode, $density, $fps)';
}

const presetLeast = StreamChoice('duogray', 'adaptive', 1);
const presetSharpest = StreamChoice('color16', 'original', 15);

/// A new session starts like today's hub-spawned client.
const startChoice = StreamChoice('color16', 'adaptive', 15);
