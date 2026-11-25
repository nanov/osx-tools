import AppKit

/// The menu-bar dropdown: a borderless panel with Control Center-style sections.
/// Its views exist only while it's open; closing it drops them.
final class StatusPanel: NSPanel {
  override var canBecomeKey: Bool { true }

  init() {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    isFloatingPanel = true
    level = .popUpMenu
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isReleasedWhenClosed = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
  }

  override func cancelOperation(_ sender: Any?) { close() }
}

final class PanelController {
  static let width: CGFloat = 300

  private let panel = StatusPanel()
  private var clickMonitor: Any?
  private var targets: [ClosureTarget] = []
  private let build: (PanelController) -> [NSView]

  var isOpen: Bool { panel.isVisible }

  init(build: @escaping (PanelController) -> [NSView]) {
    self.build = build
    NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
      [weak self] _ in self?.close()
    }
  }

  /// When the panel last closed. Clicking the menu-bar icon while the panel is open takes
  /// its focus first, which closes it; the click itself must not then reopen it.
  private var closedAt = Date.distantPast

  func toggle(below button: NSStatusBarButton) {
    if isOpen { return close() }
    guard Date().timeIntervalSince(closedAt) > 0.4 else { return }
    open(below: button)
  }

  func open(below button: NSStatusBarButton) {
    rebuild()
    guard let anchor = button.window?.frame, let screen = button.window?.screen ?? NSScreen.main else { return }
    let size = panel.contentView?.fittingSize ?? .zero
    let vis = screen.visibleFrame
    let x = min(max(anchor.minX, vis.minX + 8), vis.maxX - size.width - 8)
    panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
    panel.makeKeyAndOrderFront(nil)
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      self?.close()
    }
  }

  func close() {
    guard isOpen else { return }
    closedAt = Date()
    panel.orderOut(nil)
    if let m = clickMonitor { NSEvent.removeMonitor(m) }
    clickMonitor = nil
    panel.contentView = nil
    targets.removeAll()
  }

  /// Re-render in place (e.g. after a state change) keeping the top edge fixed.
  func refresh() {
    guard isOpen else { return }
    let top = panel.frame.maxY
    rebuild()
    let size = panel.contentView?.fittingSize ?? .zero
    panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
  }

  private func rebuild() {
    targets.removeAll()
    let stack = NSStackView(views: build(self))
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    stack.translatesAutoresizingMaskIntoConstraints = false
    for v in stack.arrangedSubviews {
      v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
    }

    let bg = NSVisualEffectView()
    bg.material = .popover
    bg.state = .active
    bg.wantsLayer = true
    bg.layer?.cornerRadius = 12
    bg.layer?.masksToBounds = true
    bg.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
      stack.topAnchor.constraint(equalTo: bg.topAnchor),
      stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
      bg.widthAnchor.constraint(equalToConstant: Self.width),
    ])
    panel.contentView = bg
    bg.layoutSubtreeIfNeeded()
    panel.invalidateShadow()
  }

  // MARK: - Building blocks

  /// Wire a control to a closure; the closure lives as long as the panel's current views.
  func on<C: NSControl>(_ control: C, _ fn: @escaping (C) -> Void) -> C {
    let t = ClosureTarget { fn($0 as! C) }
    targets.append(t)
    control.target = t
    control.action = #selector(ClosureTarget.fire(_:))
    return control
  }

  static func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                    color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    return l
  }

  static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let r = NSStackView(views: views)
    r.orientation = .horizontal
    r.alignment = .centerY
    r.spacing = spacing
    return r
  }

  static func spacer() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.init(1), for: .horizontal)
    return v
  }

  static func icon(_ symbol: String, color: NSColor = .labelColor) -> NSImageView {
    let v = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    v.contentTintColor = color
    v.symbolConfiguration = .init(pointSize: 13, weight: .medium)
    return v
  }

  static func iconButton(_ symbol: String, tip: String) -> NSButton {
    let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                     target: nil, action: nil)
    b.isBordered = false
    b.toolTip = tip
    b.symbolConfiguration = .init(pointSize: 13, weight: .regular)
    b.contentTintColor = .secondaryLabelColor
    return b
  }

  /// A rounded card holding rows, like a Control Center module.
  static func card(_ rows: [NSView]) -> NSView {
    let stack = NSStackView(views: rows)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let card = NSView()
    card.wantsLayer = true
    card.layer?.cornerRadius = 9
    card.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    card.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
      stack.topAnchor.constraint(equalTo: card.topAnchor),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
    ])
    for v in rows { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true }
    return card
  }
}

final class ClosureTarget: NSObject {
  private let fn: (NSControl) -> Void
  init(_ fn: @escaping (NSControl) -> Void) { self.fn = fn }
  @objc func fire(_ sender: NSControl) { fn(sender) }
}
