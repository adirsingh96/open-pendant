import Cocoa
import CoreGraphics
import ApplicationServices
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    CursorPastePlugin.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

private enum CursorPastePlugin {
  static let channelName = "openpendant/cursor"
  static let cursorBundle = "com.todesktop.230313mzl4w4u92"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "pasteClipboard" else {
        result(FlutterMethodNotImplemented)
        return
      }
      pasteClipboard(autoSend: boolArg(call, "autoSend"), result: result)
    }
  }

  static func boolArg(_ call: FlutterMethodCall, _ key: String) -> Bool {
    guard let args = call.arguments as? [String: Any] else {
      return false
    }
    if let b = args[key] as? Bool {
      return b
    }
    if let n = args[key] as? NSNumber {
      return n.boolValue
    }
    return false
  }

  static func pasteClipboard(autoSend: Bool, result: @escaping FlutterResult) {
    if !AXIsProcessTrusted() {
      let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        as CFDictionary
      _ = AXIsProcessTrustedWithOptions(prompt)
    }
    let trusted = AXIsProcessTrusted()
    let alreadyFront =
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == cursorBundle
    bringCursorForward { err in
      let wait = alreadyFront ? 0.12 : 0.35
      DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
        if let err {
          result(
            FlutterError(code: "activate", message: err.localizedDescription, details: nil)
          )
          return
        }
        guard let src = CGEventSource(stateID: .hidSystemState) else {
          result(
            FlutterError(code: "event", message: "Could not create key events", details: nil)
          )
          return
        }
        postKey(src: src, key: 0x09, flags: .maskCommand)
        let finish = {
          if !trusted {
            result(
              FlutterError(
                code: "accessibility",
                message:
                  "Accessibility is off for this build. System Settings → Privacy → Accessibility: remove every openpendant row, then add app/build/macos/Build/Products/Debug/openpendant.app and toggle it on.",
                details: nil
              )
            )
          } else {
            result(true)
          }
        }
        if autoSend {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            postKey(src: src, key: 0x24, flags: [])
            finish()
          }
        } else {
          finish()
        }
      }
    }
  }

  static func bringCursorForward(done: @escaping (Error?) -> Void) {
    let running = NSRunningApplication.runningApplications(
      withBundleIdentifier: cursorBundle
    )
    if let app = running.first {
      if #available(macOS 14.0, *) {
        NSApp.yieldActivation(to: app)
      }
      app.activate(options: [.activateIgnoringOtherApps])
      done(nil)
      return
    }
    guard
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cursorBundle)
    else {
      done(
        NSError(
          domain: "openpendant",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Cursor.app not found"]
        )
      )
      return
    }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
      done(err)
    }
  }

  static func postKey(src: CGEventSource, key: CGKeyCode, flags: CGEventFlags) {
    guard
      let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
      let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
    else {
      return
    }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }
}
