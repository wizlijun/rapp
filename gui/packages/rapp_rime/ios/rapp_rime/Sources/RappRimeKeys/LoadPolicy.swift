/// Whether the engine should be loaded (spec §6.6). It loads as soon as the master switch is on and a hardware
/// keyboard is there (at `configure`, or when a keyboard connects), not on the editor's first focus, so the first
/// type-to-compose after a launch, and the presses typed while it would load, already reach it. Once loaded it
/// stays while the switch is on, keyboard or not; the switch off releases it.
public enum LoadPolicy {
  public static func wanted(was: Bool, enabled: Bool, keyboard: Bool) -> Bool {
    enabled && (was || keyboard)
  }
}
