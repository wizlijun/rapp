#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif
import RappSession

/// Password storage is separate from the session command/logging channel.
final class UnlockPlugin: NSObject, FlutterPlugin {
  private let store = UnlockStore()
  private let queue = DispatchQueue(label: "rapp.unlock-store", qos: .utility)

  static func register(with registrar: FlutterPluginRegistrar) {
    #if os(macOS)
    let messenger = registrar.messenger
    #else
    let messenger = registrar.messenger()
    #endif
    let channel = FlutterMethodChannel(name: "rapp/unlock", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(UnlockPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard ["read", "save", "forget"].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any], let device = args["device"] as? String,
          !device.isEmpty else {
      result(FlutterError(code: "bad_args", message: "设备标识无效", details: nil))
      return
    }
    let method = call.method
    let password = args["password"] as? String
    let auto = args["auto"] as? Bool
    if method == "save" && (password == nil || password!.utf8.count > 1024 || auto == nil) {
      result(FlutterError(code: "bad_args", message: "密码参数无效", details: nil))
      return
    }
    queue.async { [self] in
      do {
        var value: Any?
        switch method {
        case "read":
          if let credential = try store.read(device: device) {
            value = ["password": credential.password, "auto": credential.auto]
          }
        case "save": try store.save(device: device, password: password!, auto: auto!)
        case "forget": try store.forget(device: device)
        default: break
        }
        let response = value
        DispatchQueue.main.async { result(response) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "keychain", message: keychainError, details: nil))
        }
      }
    }
  }
}

#if os(macOS)
private let keychainError = "无法访问 macOS 钥匙串"
#else
private let keychainError = "无法访问钥匙串"
#endif
