// What the user chose for one session's stream: picture mode, density and frame rate (R11, R18).
class StreamChoice {
  const StreamChoice(this.mode, this.density, this.fps, {this.smart = false});

  /// `duogray`, `duocolor` or `color16` (the runner's `set_stream` names).
  final String mode;

  /// `saver1x`, `adaptive` or `original`.
  final String density;
  final int fps;

  /// The 智能 preset: the host adapts to network and focus. Any manual change leaves it.
  final bool smart;

  @override
  bool operator ==(Object other) =>
      other is StreamChoice && other.mode == mode && other.density == density && other.fps == fps && other.smart == smart;

  @override
  int get hashCode => Object.hash(mode, density, fps, smart);

  StreamChoice copyWith({String? mode, String? density, int? fps}) =>
      StreamChoice(mode ?? this.mode, density ?? this.density, fps ?? this.fps);

  @override
  String toString() => 'StreamChoice($mode, $density, $fps${smart ? ', smart' : ''})';
}

const presetLeast = StreamChoice('duogray', 'adaptive', 1);
const presetSmart = StreamChoice('color16', 'adaptive', 15, smart: true);
const presetSharpest = StreamChoice('color16', 'original', 15);

/// A new session starts like today's hub-spawned client.
const startChoice = StreamChoice('color16', 'adaptive', 15);

/// The rate a session really streams at: its chosen one while it can be seen (on the stage of a
/// visible main window, or in a visible detached window), otherwise 0: A pauses the picture and
/// only says when it changed (protocol v15). A session without its first frame yet runs at 1 fps
/// instead, so its lamp leaves 「连接中」.
int effectiveFps(StreamChoice c, {required bool shown, bool sawFrame = true}) =>
    shown ? c.fps : (sawFrame ? 0 : 1);
