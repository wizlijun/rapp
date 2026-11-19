/// What becomes of one press type-to-compose replays into the editor while the engine is active and ready.
public enum ReplayAction: Equatable {
  /// The engine took it; its update goes to Dart.
  case engine
  /// Declined printable text, committed through Dart like a live press.
  case dart(String)
  /// A declined ⌫, applied by Dart at the caret.
  case delete
  /// Not ours: the caller handles it as before.
  case pass
}

public enum ReplayPolicy {
  /// Everything that edits the text goes through Dart once anything has: the iOS text-input copy learns of a
  /// Dart-side edit only through the async setEditingState, so a synchronous insertText or deleteBackward right
  /// after one edits a stale copy, and its full-state update overwrites what Dart did.
  public static func decide(processed: Bool, typedText: String?, isBackspace: Bool) -> ReplayAction {
    if processed { return .engine }
    if let typedText { return .dart(typedText) }
    if isBackspace { return .delete }
    return .pass
  }
}
