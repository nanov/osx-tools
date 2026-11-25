import AppKit

/// Claude Code status at the top of every screen: around the notch on the MacBook, a small
/// pill at the top centre elsewhere. The strip shows while a session is working, needs you,
/// or has just finished; click it to jump to the most urgent one. Hovering the notch or the
/// pill's spot opens the dashboard, with or without sessions: when none is live, an invisible
/// zone of the same size stays there. Animations are Core Animation, so they run in the
/// window server and cost the app nothing per frame.
final class Island {
  private let agents: Agents
  private let dashboard: Dashboard
  private var windows: [CGDirectDisplayID: IslandWindow] = [:]

  /// Applies the "Show island in screenshots" setting to the hover windows that already exist.
  func applySharing() {
    let type: NSWindow.SharingType = UserDefaults.standard.bool(forKey: "allowScreenCapture") ? .readOnly : .none
    windows.values.forEach { $0.sharingType = type }
  }
  private var hideTimer: Timer?
  private var screenObserver: NSObjectProtocol?
  /// How long a finished session keeps the strip up.
  private static let doneLinger: TimeInterval = 30

  init(agents: Agents, dashboard: Dashboard) {
    self.agents = agents
    self.dashboard = dashboard
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.dashboard.close()
      self?.windows.values.forEach { $0.orderOut(nil) }
      self?.windows.removeAll()
      self?.update()
    }
  }

  private var visibleSessions: [Agents.Session] {
    let now = Date()
    return agents.sorted.filter { $0.state != .done || now.timeIntervalSince($0.since) < Self.doneLinger }
  }

  func update() {
    let shown = visibleSessions
    hideTimer?.invalidate()
    hideTimer = nil
    // Come back when the last "done" should disappear.
    if let next = shown.filter({ $0.state == .done }).map({ $0.since.addingTimeInterval(Self.doneLinger) }).min() {
      let t = Timer(fire: next.addingTimeInterval(0.1), interval: 0, repeats: false) { [weak self] _ in self?.update() }
      RunLoop.main.add(t, forMode: .common)
      hideTimer = t
    }
    var seen = Set<CGDirectDisplayID>()
    for screen in NSScreen.screens {
      guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
      else { continue }
      seen.insert(id)
      let w = windows[id] ?? IslandWindow(screen: screen, island: self)
      windows[id] = w
      w.show(shown)
    }
    for (id, w) in windows where !seen.contains(id) {
      w.orderOut(nil)
      windows[id] = nil
    }
    dashboard.sessionsChanged()
  }

  func jump(_ s: Agents.Session) { agents.jump(to: s) }

  fileprivate func openDashboard(on screen: NSScreen, zone: NSRect, inset: CGFloat) {
    dashboard.open(on: screen, from: zone, inset: inset)
  }
}

// MARK: - Window

private final class IslandWindow: NSPanel {
  private weak var island: Island?
  private let screenRef: NSScreen
  /// Width of the camera housing; 0 on screens without a notch.
  private let notchWidth: CGFloat
  private let bandHeight: CGFloat
  private var sessions: [Agents.Session] = []
  private var openWork: DispatchWorkItem?
  private let background = NSView()

  private static let ear: CGFloat = 36

  init(screen: NSScreen, island: Island) {
    self.island = island
    screenRef = screen
    if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
      notchWidth = r.minX - l.maxX
      bandHeight = screen.safeAreaInsets.top
    } else {
      notchWidth = 0
      bandHeight = max(20, screen.frame.maxY - screen.visibleFrame.maxY - 6)
    }
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    level = .statusBar
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    // Session names stay out of screen shares unless the user opts in.
    sharingType = UserDefaults.standard.bool(forKey: "allowScreenCapture") ? .readOnly : .none
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

    background.wantsLayer = true
    let content = TrackingView()
    content.onEnter = { [weak self] in self?.hover(true) }
    content.onExit = { [weak self] in self?.hover(false) }
    content.onClick = { [weak self] in self?.clickedBand() }
    content.addSubview(background)
    contentView = content
  }

  private var hasNotch: Bool { notchWidth > 0 }

  func show(_ sessions: [Agents.Session]) {
    self.sessions = sessions
    layout()
    orderFrontRegardless()
  }

  // MARK: Layout

  /// With sessions: the strip (notch plus ears, or the pill). Without: just the notch, or
  /// the pill's spot, as a hover zone.
  private var bandFrame: NSRect {
    let f = screenRef.frame
    let idle = sessions.isEmpty
    let width = hasNotch ? notchWidth + (idle ? 0 : 2 * Self.ear) : 2 * Self.ear + 44
    let top = hasNotch ? f.maxY : f.maxY - 3
    return NSRect(x: f.midX - width / 2, y: top - bandHeight, width: width, height: bandHeight)
  }

  private func layout() {
    let target = bandFrame
    setFrame(target, display: true)
    let bounds = NSRect(origin: .zero, size: target.size)
    background.frame = bounds
    // An idle zone is nearly transparent: invisible, but still there for the mouse
    // (fully transparent pixels let events through to the menu bar).
    background.layer?.backgroundColor = sessions.isEmpty
      ? NSColor.black.withAlphaComponent(hasNotch ? 1 : 0.01).cgColor
      : NSColor.black.cgColor
    background.layer?.cornerRadius = hasNotch ? 10 : bandHeight / 2
    // Under the notch only the bottom corners round, so it reads as part of the housing.
    background.layer?.maskedCorners = hasNotch
      ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
      : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    background.subviews.forEach { $0.removeFromSuperview() }
    buildBand(in: bounds)
  }

  /// The strip: status mark left of the camera, count right of it.
  private func buildBand(in bounds: NSRect) {
    guard let top = sessions.first else { return }
    let state = top.state
    let count = sessions.filter { $0.state == state }.count
    let mark = StatusMark(state: state, size: 14)
    mark.frame = NSRect(x: (Self.ear - 14) / 2 + 4, y: (bandHeight - 14) / 2, width: 14, height: 14)
    background.addSubview(mark)

    let text: String
    if hasNotch {
      text = "\(count)"
    } else {
      text = state == .attention ? "needs you" : state == .working ? "working" : "done"
    }
    let label = NSTextField(labelWithString: hasNotch || count == 1 ? text : "\(count) \(text)")
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = StatusMark.color(state)
    label.alignment = hasNotch ? .center : .left
    label.sizeToFit()
    let lh = label.frame.height
    if hasNotch {
      label.frame = NSRect(x: bounds.width - Self.ear - 4, y: (bandHeight - lh) / 2, width: Self.ear, height: lh)
    } else {
      label.frame = NSRect(x: mark.frame.maxX + 8, y: (bandHeight - lh) / 2,
                           width: bounds.width - mark.frame.maxX - 16, height: lh)
    }
    background.addSubview(label)
  }

  // MARK: Interaction

  /// A short pause before opening, so sweeping past the top of the screen doesn't.
  private func hover(_ inside: Bool) {
    openWork?.cancel()
    guard inside else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let menuBar = screenRef.frame.maxY - screenRef.visibleFrame.maxY
      island?.openDashboard(on: screenRef, zone: frame, inset: max(bandHeight, menuBar))
    }
    openWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }

  /// Clicking the strip jumps to the most urgent session.
  private func clickedBand() {
    openWork?.cancel()
    guard let s = sessions.first else { return }
    island?.jump(s)
  }
}

// MARK: - Views

private final class TrackingView: NSView {
  var onEnter: (() -> Void)?
  var onExit: (() -> Void)?
  var onClick: (() -> Void)?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self))
  }

  override func mouseEntered(with event: NSEvent) { onEnter?() }
  override func mouseExited(with event: NSEvent) { onExit?() }
  override func mouseDown(with event: NSEvent) { onClick?() }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Working: three pulsing dots. Needs you: a breathing orange dot. Done: a green check.
private final class StatusMark: NSView {
  static func color(_ s: Agents.State) -> NSColor {
    switch s {
    case .working: return .white
    case .attention: return .systemOrange
    case .done: return .systemGreen
    }
  }

  init(state: Agents.State, size: CGFloat) {
    super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    wantsLayer = true
    guard let root = layer else { return }
    let color = Self.color(state).cgColor
    switch state {
    case .working:
      let d = size / 4
      for i in 0..<3 {
        let dot = CALayer()
        dot.frame = CGRect(x: CGFloat(i) * (size - d) / 2, y: (size - d) / 2, width: d, height: d)
        dot.cornerRadius = d / 2
        dot.backgroundColor = color
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0.25
        a.duration = 0.6
        a.autoreverses = true
        a.repeatCount = .infinity
        a.beginTime = CACurrentMediaTime() + Double(i) * 0.2
        dot.add(a, forKey: "pulse")
        root.addSublayer(dot)
      }
    case .attention:
      let dot = CALayer()
      dot.frame = CGRect(x: size * 0.15, y: size * 0.15, width: size * 0.7, height: size * 0.7)
      dot.cornerRadius = size * 0.35
      dot.backgroundColor = color
      let a = CABasicAnimation(keyPath: "transform.scale")
      a.fromValue = 0.8
      a.toValue = 1.15
      a.duration = 0.7
      a.autoreverses = true
      a.repeatCount = .infinity
      dot.add(a, forKey: "breathe")
      root.addSublayer(dot)
    case .done:
      let img = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)!)
      img.symbolConfiguration = .init(pointSize: size, weight: .semibold)
      img.contentTintColor = Self.color(state)
      img.frame = bounds
      addSubview(img)
    }
  }

  required init?(coder: NSCoder) { fatalError() }
}
