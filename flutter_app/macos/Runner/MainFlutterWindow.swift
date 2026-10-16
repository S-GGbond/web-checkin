import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    // 后台签到模式（launchd 唤起）：完全不显示窗口，也不出现在 Dock 中。
    if MainFlutterWindow.isBackgroundMode() {
      self.orderOut(nil)
      NSApp.setActivationPolicy(.accessory)
    }
  }

  private static func isBackgroundMode() -> Bool {
    if ProcessInfo.processInfo.environment["CHECKIN_HUB_BACKGROUND"] != nil {
      return true
    }
    return CommandLine.arguments.contains("--background-checkin")
  }
}
