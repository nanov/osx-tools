import AppKit

/// Brightness indicator: a dark capsule in the top-right of the target screen, like the
/// system's. The window exists only while it's on screen and is released after it fades.
final class OSD {
  private var panel: NSPanel?
  private var fill: NSView?
  private var fillWidth: NSLayoutConstraint?
  private var hideWork: DispatchWorkItem?
  /// Bumped on every show, so a fade that finishes after a newer show doesn't hide it.
  private var generation = 0

  private static let size = NSSize(width: 260, height: 44)
  private static let barWidth: CGFloat = 180

  func show(level: Double, on displayID: CGDirectDisplayID) {
    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
    generation += 1
    let p = panel ?? make()
    let vis = screen.visibleFrame
    p.setFrame(NSRect(x: vis.maxX - Self.size.width - 12, y: vis.maxY - Self.size.height - 8,
                      width: Self.size.width, height: Self.size.height), display: false)
    fillWidth?.constant = Self.barWidth * min(max(level, 0), 1)
    p.contentView?.layoutSubtreeIfNeeded()
    if !p.isVisible || p.alphaValue < 1 {
      p.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { $0.duration = 0.1; p.animator().alphaValue = 1 }
    }

    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.hide() }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
  }

  private func hide() {
    guard let p = panel else { return }
    let gen = generation
    NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }) { [weak self] in
      guard let self, gen == generation else { return }
      panel?.orderOut(nil)
      panel = nil
      fill = nil
      fillWidth = nil
    }
  }

  private func make() -> NSPanel {
    let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    p.level = .screenSaver
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.ignoresMouseEvents = true
    p.sharingType = .none
    p.isReleasedWhenClosed = false
    p.alphaValue = 0
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

    let bg = NSVisualEffectView()
    bg.material = .hudWindow
    bg.state = .active
    bg.appearance = NSAppearance(named: .darkAqua)
    bg.wantsLayer = true
    bg.layer?.cornerRadius = Self.size.height / 2
    bg.layer?.masksToBounds = true

    let sun = NSImageView(image: NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)!)
    sun.symbolConfiguration = .init(pointSize: 15, weight: .medium)
    sun.contentTintColor = .white

    let track = NSView()
    track.wantsLayer = true
    track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
    track.layer?.cornerRadius = 3
    let fill = NSView()
    fill.wantsLayer = true
    fill.layer?.backgroundColor = NSColor.white.cgColor
    fill.layer?.cornerRadius = 3

    for v in [sun, track, fill] {
      v.translatesAutoresizingMaskIntoConstraints = false
      bg.addSubview(v)
    }
    let fw = fill.widthAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      sun.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 22),
      sun.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
      track.leadingAnchor.constraint(equalTo: sun.trailingAnchor, constant: 14),
      track.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
      track.widthAnchor.constraint(equalToConstant: Self.barWidth),
      track.heightAnchor.constraint(equalToConstant: 6),
      fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
      fill.centerYAnchor.constraint(equalTo: track.centerYAnchor),
      fill.heightAnchor.constraint(equalTo: track.heightAnchor),
      fw,
    ])
    p.contentView = bg
    panel = p
    self.fill = fill
    fillWidth = fw
    return p
  }
}
