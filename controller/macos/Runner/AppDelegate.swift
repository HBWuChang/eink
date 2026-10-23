import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var activity: NSObjectProtocol?
  private var statusItem: NSStatusItem?
  private var backgroundChannel: FlutterMethodChannel?
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "EPD"
    let menu = NSMenu()
    menu.addItem(withTitle: "打开墨水屏控制器", action: #selector(showWindow), keyEquivalent: "")
    menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "")
    for entry in menu.items { entry.target = self }
    item.menu = menu
    statusItem = item
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "epd/background", binaryMessenger: controller.engine.binaryMessenger)
      backgroundChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "setEnabled", let enabled = call.arguments as? Bool else {
          result(FlutterMethodNotImplemented); return
        }
        self?.setBackgroundEnabled(enabled)
        result(nil)
      }
    }
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
  }
  private func setBackgroundEnabled(_ enabled: Bool) {
    if let current = activity { ProcessInfo.processInfo.endActivity(current); activity = nil }
    if enabled {
      activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "定时更新蓝牙墨水屏 YT 状态")
    }
  }
  @objc private func didWake() { backgroundChannel?.invokeMethod("wake", arguments: nil) }
  @objc private func showWindow() {
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  @objc private func quitApp() { NSApp.terminate(nil) }
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showWindow(); return true
  }
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
