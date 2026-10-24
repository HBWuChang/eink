import Cocoa
import FlutterMacOS
import IOKit.pwr_mgt
import CoreText

@main
class AppDelegate: FlutterAppDelegate {
  private var activity: NSObjectProtocol?
  private var statusItem: NSStatusItem?
  private var statusActivationObserver: NSObjectProtocol?
  private var backgroundChannel: FlutterMethodChannel?
  private var backgroundTimer: DispatchSourceTimer?
  private var sleepAssertion = IOPMAssertionID(0)
  private var enabled = false
  private var lastTick: Date?
  private weak var retainedWindow: NSWindow?

  // Install while the Flutter window is created, before Dart initializes Hive.
  func configureBackground(controller: FlutterViewController, window: NSWindow) {
    retainedWindow = window
    ensureStatusItem()
    if statusActivationObserver == nil {
      statusActivationObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.ensureStatusItem() }
    }
    let channel = FlutterMethodChannel(name: "epd/background", binaryMessenger: controller.engine.binaryMessenger)
    backgroundChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      self.ensureStatusItem()
      switch call.method {
      case "setEnabled":
        guard let value = call.arguments as? Bool else { result(FlutterError(code: "arguments", message: "Expected Bool", details: nil)); return }
        self.setBackgroundEnabled(value)
        result(self.backgroundStatus())
      case "getStatus": result(self.backgroundStatus())
      case "renderText":
        guard let rows = call.arguments as? [[String: Any]],
              let png = Self.renderText(rows: rows) else {
          result(FlutterError(code: "render", message: "CPU text rendering failed", details: nil)); return
        }
        result(FlutterStandardTypedData(bytes: png))
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func backgroundStatus() -> [String: Any] {
    return ["enabled": enabled, "sleepAssertion": sleepAssertion != 0,
            "lastTick": lastTick?.timeIntervalSince1970 ?? 0,
            "statusItemVisible": statusItem?.isVisible ?? false]
  }

  // CoreText draws into CPU memory, independent of Flutter's frame/GPU lifecycle.
  static func renderText(rows: [[String: Any]]) -> Data? {
    let width = 480, height = 264
    guard let context = CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    for row in rows {
      guard let value = row["text"] as? String,
            let size = row["size"] as? Double, let y = row["y"] as? Double,
            let argb = row["color"] as? NSNumber else { return nil }
      let rgb = argb.uint32Value
      let color = CGColor(red: CGFloat((rgb >> 16) & 255) / 255,
                          green: CGFloat((rgb >> 8) & 255) / 255,
                          blue: CGFloat(rgb & 255) / 255, alpha: 1)
      let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
      let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
      let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
      let clipped = CTLineCreateTruncatedLine(line, 456, .end, ellipsis) ?? line
      context.textPosition = CGPoint(x: 12, y: Double(height) - y - CTFontGetAscent(font))
      CTLineDraw(clipped, context)
    }
    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    if backgroundChannel == nil, let window = mainFlutterWindow,
       let controller = window.contentViewController as? FlutterViewController {
      configureBackground(controller: controller, window: window)
    }
    ensureStatusItem()
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
  }
  private func ensureStatusItem() {
    if let item = statusItem {
      item.isVisible = true
      return
    }
    let item = NSStatusBar.system.statusItem(withLength: 44)
    item.autosaveName = "EPDStatusItem"
    item.behavior = []
    item.isVisible = true
    item.button?.title = "EPD"
    item.button?.toolTip = "HUAWEI A0 墨水屏控制器"
    let menu = NSMenu()
    menu.addItem(withTitle: "打开墨水屏控制器", action: #selector(showWindow), keyEquivalent: "")
    menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "")
    for entry in menu.items { entry.target = self }
    item.menu = menu
    statusItem = item
  }

  private func setBackgroundEnabled(_ value: Bool) {
    enabled = value
    backgroundTimer?.cancel()
    backgroundTimer = nil
    if let current = activity { ProcessInfo.processInfo.endActivity(current); activity = nil }
    if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
    if value {
      activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "定时更新蓝牙墨水屏 YT 状态")
      let code = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn), "EPD YT scheduled refresh" as CFString, &sleepAssertion)
      if code != kIOReturnSuccess { sleepAssertion = 0 }
      let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
      timer.schedule(deadline: .now() + 600, repeating: 600, leeway: .seconds(1))
      timer.setEventHandler { [weak self] in
        guard let self = self, self.enabled else { return }
        self.lastTick = Date()
        NSLog("[EPD background] tick; sleep assertion=%u", self.sleepAssertion)
        self.backgroundChannel?.invokeMethod("tick", arguments: nil)
      }
      backgroundTimer = timer
      timer.resume()
    }
    NSLog("[EPD background] enabled=%d sleep assertion=%u", value, sleepAssertion)
  }
  @objc private func didWake() { ensureStatusItem(); backgroundChannel?.invokeMethod("wake", arguments: nil) }
  @objc private func showWindow() {
    (retainedWindow ?? mainFlutterWindow)?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  @objc private func quitApp() { NSApp.terminate(nil) }
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showWindow(); return true
  }
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
