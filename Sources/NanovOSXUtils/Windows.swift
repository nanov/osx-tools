import AppKit
import ApplicationServices

// All geometry here is in global CG coordinates (origin top-left of the primary display),
// which is what AX, CGWindowList and CGWarpMouseCursorPosition use.

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ el: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Displays

struct Display {
  let id: CGDirectDisplayID
  let frame: CGRect
  let visible: CGRect

  static func all() -> [Display] {
    let screens = NSScreen.screens
    guard let primaryH = screens.first?.frame.height else { return [] }
    func cg(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height) }
    return screens.map {
      let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
      return Display(id: id, frame: cg($0.frame), visible: cg($0.visibleFrame))
    }
  }

  static func containing(_ p: CGPoint, in displays: [Display] = all()) -> Display? {
    displays.first { $0.frame.contains(p) }
      ?? displays.min { $0.frame.center.distance(to: p) < $1.frame.center.distance(to: p) }
  }

  /// Nearest display lying entirely beyond this one's edge in `dir`.
  func neighbor(_ dir: Direction, in displays: [Display] = all()) -> Display? {
    let tol: CGFloat = 10
    return displays.filter { o in
      guard o.id != id else { return false }
      switch dir {
      case .right: return o.frame.minX >= frame.maxX - tol
      case .left: return o.frame.maxX <= frame.minX + tol
      case .down: return o.frame.minY >= frame.maxY - tol
      case .up: return o.frame.maxY <= frame.minY + tol
      }
    }.min { $0.frame.center.distance(to: frame.center) < $1.frame.center.distance(to: frame.center) }
  }
}

extension CGRect {
  var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension CGPoint {
  func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
}

// MARK: - Accessibility

enum AX {
  static var trusted: Bool { AXIsProcessTrusted() }

  static func promptIfNeeded() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
  }

  static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
    guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
  }

  static func windows(_ app: AXUIElement) -> [AXUIElement] {
    (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
  }

  static func focusedWindow() -> AXUIElement? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    return element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
  }

  static func isStandard(_ w: AXUIElement) -> Bool {
    (value(w, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole
  }

  static func isMinimized(_ w: AXUIElement) -> Bool {
    (value(w, kAXMinimizedAttribute) as? Bool) ?? false
  }

  static func frame(_ w: AXUIElement) -> CGRect? {
    guard let p = value(w, kAXPositionAttribute), let s = value(w, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
          AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
  }

  static func setFrame(_ w: AXUIElement, _ r: CGRect) {
    var origin = r.origin, size = r.size
    let p = AXValueCreate(.cgPoint, &origin)!, s = AXValueCreate(.cgSize, &size)!
    // Size first so the move isn't clamped by the old size, then again in case the
    // app limited the size against the old screen.
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s)
  }

  static func focus(_ w: AXUIElement) {
    var pid: pid_t = 0
    AXUIElementGetPid(w, &pid)
    if let app = NSRunningApplication(processIdentifier: pid), app.isHidden { app.unhide() }
    AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
  }

  /// Topmost standard window whose centre lies on `display`, front to back.
  static func frontWindow(on display: Display) -> AXUIElement? {
    let me = ProcessInfo.processInfo.processIdentifier
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] else { return nil }
    var appCache: [pid_t: [AXUIElement]] = [:]
    for info in list {
      guard (info[kCGWindowLayer as String] as? Int) == 0,
            let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
            let wid = info[kCGWindowNumber as String] as? CGWindowID,
            let b = info[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: b),
            display.frame.contains(rect.center) else { continue }
      let wins = appCache[pid] ?? windows(AXUIElementCreateApplication(pid))
      appCache[pid] = wins
      if let w = wins.first(where: { var id: CGWindowID = 0; return _AXUIElementGetWindow($0, &id) == .success && id == wid }),
         isStandard(w) {
        return w
      }
    }
    return nil
  }
}

// MARK: - Cursor

enum Cursor {
  static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

  static func warp(_ p: CGPoint) {
    CGWarpMouseCursorPosition(p)
    CGAssociateMouseAndMouseCursorPosition(1)
  }
}
