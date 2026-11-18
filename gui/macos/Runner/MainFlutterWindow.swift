import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// The system's text size, read once by Dart at start.
  private var systemChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    // Before Flutter starts: a second main instance only hands off and quits.
    if !SingleInstance.isConnectionManager && !SingleInstance.claim() {
      SingleInstance.handOff()
      exit(0)
    }
    // Forward process arguments (minus argv[0]) to Dart's main(args), e.g. `--cm`.
    let project = FlutterDartProject()
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())
    let flutterViewController = FlutterViewController(project: project)
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    UnlockPlugin.register(with: flutterViewController.registrar(forPlugin: "RappUnlock"))
    SessionPlugin.register(with: flutterViewController.registrar(forPlugin: "RappSession"))
    SecureInputPlugin.register(with: flutterViewController.registrar(forPlugin: "RappSecureInput"), window: self)

    SpeechPlugin.register(with: flutterViewController.registrar(forPlugin: "RappSpeech"), window: self)

    ComposerPlugin.register(with: flutterViewController.registrar(forPlugin: "RappComposer"))

    let system = FlutterMethodChannel(name: "rapp/system", binaryMessenger: flutterViewController.engine.binaryMessenger)
    system.setMethodCallHandler { call, result in
      if call.method == "fontSize" {
        result(Double(NSFont.systemFontSize))
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    systemChannel = system

    super.awakeFromNib()
  }
}
