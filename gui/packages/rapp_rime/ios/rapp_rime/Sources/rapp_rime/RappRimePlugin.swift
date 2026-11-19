import CRime
import Flutter
import UIKit

public final class RappRimePlugin: NSObject, FlutterPlugin {
  public static private(set) var shared: RappRimePlugin?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "rapp/rime", binaryMessenger: registrar.messenger())
    let instance = RappRimePlugin()
    shared = instance
    registrar.addMethodCallDelegate(instance, channel: channel)
    NSLog("rapp_rime: librime %@", instance.version)
  }

  private var version: String {
    rime_get_api().pointee.get_version().map { String(cString: $0) } ?? "unknown"
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "version": result(version)
    default: result(FlutterMethodNotImplemented)
    }
  }
}
