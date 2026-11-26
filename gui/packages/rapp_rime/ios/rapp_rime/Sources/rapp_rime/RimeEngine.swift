import CRime
import Foundation

/// librime in the app. Main thread only, except `join_maintenance_thread`, which runs on a background queue
/// while `loading` is true; nothing else may touch the engine until the load finishes.
final class RimeEngine {
  enum Dictionary: String {
    case bundled, user
  }

  enum State: Equatable {
    case off, starting, ready, error(String)
  }

  private(set) var state: State = .off {
    didSet { if state != oldValue { onState?(state) } }
  }
  /// The dictionary of the current load attempt (ready, failed or still loading); nil once released.
  private(set) var loaded: Dictionary?
  private(set) var loading = false
  var ready: Bool { state == .ready }
  var onState: ((State) -> Void)?

  private let api = rime_get_api().pointee
  private var session: RimeSessionId = 0
  private var initialized = false
  private var generation = 0
  /// librime said `deploy`/`failure` during the current load.
  private var deployError: String?

  private static weak var current: RimeEngine?
  private static var setupDone = false

  init() { Self.current = self }

  // MARK: folders

  static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
  /// 「我的目录」: Files app → rApp → Rime. Both the shared and the user dir, so no bundled `default.custom.yaml`
  /// can patch the user's `schema_list`.
  static var userFolder: URL { documents.appendingPathComponent("Rime", isDirectory: true) }
  static var userFolderReady: Bool {
    FileManager.default.fileExists(atPath: userFolder.appendingPathComponent("default.yaml").path)
  }
  private static var bundledData: URL { Bundle.module.bundleURL.appendingPathComponent("RimeData", isDirectory: true) }
  private static var bundledUser: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Rime", isDirectory: true)
  }

  static func dirs(_ d: Dictionary) -> (shared: URL, user: URL) {
    switch d {
    case .bundled: return (bundledData, bundledUser)
    case .user: return (userFolder, userFolder)
    }
  }

  private static func distributionVersion(_ d: Dictionary) -> String {
    guard d == .bundled else { return "user" }
    let file = bundledData.appendingPathComponent("rapp_rime_data_version")
    let v = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    return v.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
  }

  /// Removes the compiled tables, so the next load deploys from scratch. Not while loading.
  static func removeBuild(_ d: Dictionary) {
    try? FileManager.default.removeItem(at: dirs(d).user.appendingPathComponent("build", isDirectory: true))
  }

  // MARK: lifecycle

  /// Loads `d` (releasing whatever is loaded first): `initialize` and `start_maintenance` here on the main thread,
  /// the join on a background queue, then `create_session` back on main. `done` runs on main when it settles.
  func start(_ d: Dictionary, done: @escaping () -> Void) {
    precondition(!loading, "RimeEngine.start while loading")
    teardown()
    loaded = d
    let (shared, user) = Self.dirs(d)
    if d == .user, !Self.userFolderReady {
      state = .error("「文件」→ rApp → Rime 里没有 default.yaml")
      done()
      return
    }
    let fm = FileManager.default
    let logs = user.appendingPathComponent("logs", isDirectory: true)
    try? fm.createDirectory(at: logs, withIntermediateDirectories: true)

    var traits = RimeTraits()
    traits.data_size = Int32(MemoryLayout<RimeTraits>.stride - MemoryLayout<Int32>.stride)
    let keep = [shared.path, user.path, logs.path, "rime.rapp", "rapp", Self.distributionVersion(d)].map { strdup($0)! }
    traits.shared_data_dir = UnsafePointer(keep[0])
    traits.user_data_dir = UnsafePointer(keep[1])
    traits.log_dir = UnsafePointer(keep[2])
    traits.app_name = UnsafePointer(keep[3])
    traits.distribution_code_name = UnsafePointer(keep[4])
    traits.distribution_version = UnsafePointer(keep[5])
    traits.min_log_level = 2 // errors only
    if !Self.setupDone {
      // glog keeps the app_name pointer it is given, so setup gets copies that are never freed.
      var once = traits
      once.app_name = UnsafePointer(strdup("rime.rapp")!)
      once.log_dir = UnsafePointer(strdup(logs.path)!)
      api.setup!(&once)
      Self.setupDone = true
    }
    api.set_notification_handler!({ _, _, type, value in
      let t = type.map { String(cString: $0) } ?? "", v = value.map { String(cString: $0) } ?? ""
      DispatchQueue.main.async { RimeEngine.current?.notified(t, v) }
    }, nil)

    generation += 1
    let gen = generation
    deployError = nil
    loading = true
    state = .starting
    api.initialize!(&traits)
    initialized = true
    _ = api.start_maintenance!(1)
    let join = api.join_maintenance_thread!
    DispatchQueue.global(qos: .userInitiated).async {
      join()
      DispatchQueue.main.async { [weak self] in
        keep.forEach { free($0) }
        guard let self, gen == self.generation else { return }
        self.loading = false
        if let error = self.deployError {
          self.state = .error(error)
        } else {
          self.session = self.api.create_session!()
          self.state = self.session != 0 ? .ready : .error("建立会话失败")
        }
        done()
      }
    }
  }

  /// Destroys the session, then finalizes; pushes `off`. Not while loading.
  func stop() {
    precondition(!loading, "RimeEngine.stop while loading")
    teardown()
    loaded = nil
    state = .off
  }

  private func teardown() {
    if session != 0 { _ = api.destroy_session!(session); session = 0 }
    if initialized { api.finalize!(); initialized = false }
  }

  private func notified(_ type: String, _ value: String) {
    guard type == "deploy", value == "failure" else { return }
    let message = "部署失败"
    if loading { deployError = message } else if initialized { state = .error(message) }
  }

  // MARK: session

  /// One key into the engine; true when it took the key.
  func process(_ keysym: Int32, _ mask: Int32) -> Bool {
    guard ready else { return false }
    return api.process_key!(session, keysym, mask) != 0
  }

  /// The raw input being composed ("nihao"), empty when not composing.
  var input: String {
    guard ready, let p = api.get_input!(session) else { return "" }
    return String(cString: p)
  }

  var ascii: Bool { ready && api.get_option!(session, "ascii_mode") != 0 }

  func setAscii(_ on: Bool) { if ready { api.set_option!(session, "ascii_mode", on ? 1 : 0) } }
  func clear() { if ready { api.clear_composition!(session) } }
  func select(_ index: Int) { if ready { _ = api.select_candidate_on_current_page!(session, index) } }
  func page(next: Bool) { if ready { _ = api.change_page!(session, next ? 0 : 1) } }

  /// The `update` payload: what to commit (the engine's pending commit, then `extra`), the composition and the menu.
  func update(extra: String = "") -> [String: Any] {
    var commitText = ""
    var preedit = "", caret = 0
    var rows: [[String: Any]] = []
    var cursor = -1, previous = false, next = false
    if ready {
      var commit = RimeCommit()
      commit.data_size = Int32(MemoryLayout<RimeCommit>.stride - MemoryLayout<Int32>.stride)
      if api.get_commit!(session, &commit) != 0 {
        commitText = commit.text.map { String(cString: $0) } ?? ""
        _ = api.free_commit!(&commit)
      }
      var ctx = RimeContext()
      ctx.data_size = Int32(MemoryLayout<RimeContext>.stride - MemoryLayout<Int32>.stride)
      if api.get_context!(session, &ctx) != 0 {
        if let p = ctx.composition.preedit {
          preedit = String(cString: p)
          caret = Self.utf16(p, Int(ctx.composition.cursor_pos))
        }
        let menu = ctx.menu
        let keys = menu.select_keys.map { Array(String(cString: $0)).map(String.init) }
        for i in 0..<Int(menu.num_candidates) {
          let c = menu.candidates[i]
          var label = keys.flatMap { i < $0.count ? $0[i] : nil } ?? "\((i + 1) % 10)"
          if let sl = ctx.select_labels, let l = sl[i] { label = String(cString: l) }
          var text = c.text.map { String(cString: $0) } ?? ""
          if let comment = c.comment.map({ String(cString: $0) }), !comment.isEmpty { text += " \(comment)" }
          rows.append(["index": i, "label": label, "text": text])
        }
        cursor = Int(menu.highlighted_candidate_index)
        previous = menu.page_no > 0
        next = menu.is_last_page == 0 && menu.num_candidates > 0
        _ = api.free_context!(&ctx)
      }
    }
    return [
      "commit": commitText + extra, "preedit": preedit, "caret": caret, "input": input, "ascii": ascii,
      "menu": ["rows": rows, "cursor": cursor, "previous": previous, "next": next],
    ]
  }

  /// Byte offset in UTF-8 → offset in UTF-16 units (what Dart strings count).
  private static func utf16(_ p: UnsafePointer<CChar>, _ bytes: Int) -> Int {
    let utf8 = Array(String(cString: p).utf8)
    let n = max(0, min(bytes, utf8.count))
    return String(decoding: utf8[0..<n], as: UTF8.self).utf16.count
  }
}
