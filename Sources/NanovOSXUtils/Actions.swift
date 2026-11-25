import AppKit

final class Actions {
  let keepAwake = KeepAwake()
  var onClipboard: ((Bool) -> Void)?
  /// Last cursor position per display, so jumping back lands where you left off.
  private var lastCursor: [CGDirectDisplayID: CGPoint] = [:]
  private var appWait: Timer?

  func run(_ action: Action) {
    switch action {
    case .focusScreen(let d): focusScreen(d)
    case .moveWindowToScreen(let d): moveWindow(d)
    case .focusApp(let id): focusApp(id)
    case .toggleKeepAwake(let minutes): keepAwake.toggle(minutes: minutes)
    case .clipboardHistory: onClipboard?(false)
    case .pastePlain: onClipboard?(true)
    }
  }

  /// Focus a window and bring the cursor along: remember where it sat on the display
  /// we're leaving, then restore the target display's remembered spot if it still lands
  /// inside the target window, else centre it.
  private func focusWithCursor(_ win: AXUIElement?, on target: Display) {
    let here = Cursor.location
    if let d = Display.containing(here) { lastCursor[d.id] = here }
    if let win { AX.focus(win) }
    let r = win.flatMap(AX.frame) ?? target.frame
    if let p = lastCursor[target.id], r.contains(p) { Cursor.warp(p) } else { Cursor.warp(r.center) }
  }

  private func focusScreen(_ dir: Direction) {
    let displays = Display.all()
    let anchor = AX.focusedWindow().flatMap(AX.frame)?.center ?? Cursor.location
    guard let cur = Display.containing(anchor, in: displays),
          let target = cur.neighbor(dir, in: displays) else { return }
    focusWithCursor(AX.frontWindow(on: target), on: target)
  }

  /// Move the focused window to the neighbour display, keeping its proportions.
  private func moveWindow(_ dir: Direction) {
    let displays = Display.all()
    guard let win = AX.focusedWindow(), let f = AX.frame(win),
          let src = Display.containing(f.center, in: displays),
          let dst = src.neighbor(dir, in: displays) else { return }
    let s = src.visible, d = dst.visible
    let sx = d.width / s.width, sy = d.height / s.height
    var r = CGRect(x: d.minX + (f.minX - s.minX) * sx, y: d.minY + (f.minY - s.minY) * sy,
                   width: f.width * sx, height: f.height * sy)
    r = r.intersection(d).isNull ? CGRect(origin: d.origin, size: r.size) : r
    AX.setFrame(win, r)
    Cursor.warp((AX.frame(win) ?? r).center)
  }

  /// Open or focus an app. If it's running with a usable window, focus that directly;
  /// otherwise ask Launch Services to open/reopen it (which makes a new window, like a
  /// Dock click), then follow the window with the cursor once it appears.
  private func focusApp(_ bundleID: String) {
    appWait?.invalidate()
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
      let el = AXUIElementCreateApplication(app.processIdentifier)
      let win = AX.element(el, kAXMainWindowAttribute) ?? AX.windows(el).first { !AX.isMinimized($0) }
      if let win, !AX.isMinimized(win) {
        focusWithCursor(win, on: Display.containing(AX.frame(win)?.center ?? .zero) ?? Display.all()[0])
        return
      }
    }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: cfg)

    let deadline = Date().addingTimeInterval(3)
    appWait = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
      guard let self else { return t.invalidate() }
      if Date() > deadline { return t.invalidate() }
      guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
            let win = AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXMainWindowAttribute),
            let f = AX.frame(win), let d = Display.containing(f.center) else { return }
      t.invalidate()
      focusWithCursor(win, on: d)
    }
  }
}
