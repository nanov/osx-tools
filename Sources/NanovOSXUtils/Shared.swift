import AppKit

// Small helpers used across the app's views and timers.

/// A one-line, non-editable label sized to its text, truncating at the tail.
func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
           digits: Bool = false) -> NSTextField {
  let l = NSTextField(labelWithString: s)
  l.font = digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
  l.textColor = color
  l.lineBreakMode = .byTruncatingTail
  l.sizeToFit()
  return l
}

extension NSImage {
  /// An SF Symbol at a point size and weight; an empty image if the name is unknown.
  static func symbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular,
                     description: String? = nil) -> NSImage {
    NSImage(systemSymbolName: name, accessibilityDescription: description)?
      .withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? NSImage()
  }
}

extension NSView {
  /// Constrains all four edges to `other`'s.
  func pin(to other: NSView) {
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      leadingAnchor.constraint(equalTo: other.leadingAnchor),
      trailingAnchor.constraint(equalTo: other.trailingAnchor),
      topAnchor.constraint(equalTo: other.topAnchor),
      bottomAnchor.constraint(equalTo: other.bottomAnchor),
    ])
  }
}

extension NSView {
  /// Hover tracking over whatever part of the view is visible. Added once: with
  /// `.inVisibleRect` AppKit keeps the area in step with the view's size.
  func trackHover() {
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self))
  }
}

extension NSScreen {
  /// The screen's CoreGraphics display ID.
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
}

extension Timer {
  /// A repeating timer on the main run loop in common modes, so it also fires while a menu
  /// is open or a view is tracking the mouse.
  static func every(_ interval: TimeInterval, tolerance: TimeInterval, _ block: @escaping () -> Void) -> Timer {
    let t = Timer(timeInterval: interval, repeats: true) { _ in block() }
    t.tolerance = tolerance
    RunLoop.main.add(t, forMode: .common)
    return t
  }
}

/// A template image (an app's menu-bar glyph) filled with one colour, drawn by Core Animation
/// so a pulse costs the app nothing per frame.
final class TemplateMark: NSView {
  private let fill = CALayer()

  init(_ image: NSImage, size: CGFloat, color: NSColor) {
    super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    wantsLayer = true
    fill.frame = bounds
    fill.backgroundColor = color.cgColor
    let mask = CALayer()
    mask.frame = bounds
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    mask.contentsScale = scale
    mask.contents = image.layerContents(forContentsScale: scale)
    mask.contentsGravity = .resizeAspect
    fill.mask = mask
    layer?.addSublayer(fill)
  }

  required init?(coder: NSCoder) { fatalError() }

  func pulse(fast: Bool) {
    let a = CABasicAnimation(keyPath: "opacity")
    a.fromValue = 1
    a.toValue = 0.35
    a.duration = fast ? 0.5 : 0.9
    a.autoreverses = true
    a.repeatCount = .infinity
    fill.add(a, forKey: "pulse")
  }
}
