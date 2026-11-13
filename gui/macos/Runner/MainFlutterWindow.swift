import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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
    SessionPlugin.register(with: flutterViewController.registrar(forPlugin: "RappSession"))

    super.awakeFromNib()
  }
}
