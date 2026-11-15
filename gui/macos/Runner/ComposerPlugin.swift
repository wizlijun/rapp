import Cocoa
import FlutterMacOS

/// AppKitView lets Flutter compose its menus above the editor and move/clip it with the panel.
final class ComposerPlugin: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger }

  static func register(with registrar: FlutterPluginRegistrar) {
    registrar.register(ComposerPlugin(messenger: registrar.messenger), withId: "rapp/composer")
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? { FlutterStandardMessageCodec.sharedInstance() }

  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let view = RappComposerView(frame: .zero)
    let editorId = (args as? [String: Any])?["editorId"] as? Int64 ?? viewId
    let channel = FlutterMethodChannel(name: "rapp/composer/editor-\(editorId)", binaryMessenger: messenger)
    if let style = args as? [String: Any] { view.configure(style) }
    // Retain the editor through the final read on detach, even after AppKitView leaves the tree.
    channel.setMethodCallHandler { call, result in
      if call.method == "dispose" {
        view.close()
        view.event = nil
        channel.setMethodCallHandler(nil)
        result(nil)
      } else if call.method == "style", let style = call.arguments as? [String: Any] {
        view.configure(style)
        result(nil)
      } else if ["focus", "unfocus", "set", "insert", "read", "take"].contains(call.method) {
        view.perform(call.method, text: call.arguments as? String, reply: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    view.event = { method, args, reply in channel.invokeMethod(method, arguments: args, result: reply) }
    channel.invokeMethod("ready", arguments: nil)
    return view
  }
}
