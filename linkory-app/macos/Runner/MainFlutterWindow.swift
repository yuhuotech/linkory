import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Launch at login via SMAppService (works inside the sandbox).
    let channel = FlutterMethodChannel(name: "com.yuhuo.linkory/autostart", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard #available(macOS 13.0, *) else { return result(call.method == "isEnabled" ? false : nil) }
      switch call.method {
      case "isEnabled":
        result(SMAppService.mainApp.status == .enabled)
      case "set":
        do {
          if (call.arguments as? Bool) == true { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
          result(nil)
        } catch {
          result(FlutterError(code: "autostart", message: error.localizedDescription, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
