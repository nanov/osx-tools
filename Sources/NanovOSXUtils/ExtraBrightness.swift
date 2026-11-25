import AppKit
import Metal
import QuartzCore

/// Pushes the built-in XDR panel past its SDR maximum using its HDR (EDR) headroom.
///
/// How: transparent windows over the screen hold a 2×2 CAMetalLayer with a "multiply"
/// compositing filter, cleared to a value above 1.0, so the window server multiplies
/// everything beneath it. A 1-point EDR window makes macOS open the headroom. macOS takes
/// the headroom back about a second after the last EDR frame, so while on we present every
/// 0.25 s. When off, everything (windows, Metal device, timer) is released.
final class ExtraBrightness {
  /// The feature is enabled: brightness above 100% is available.
  private(set) var isOn = false
  /// 0…1 portion of the boost. At 0 the overlay is torn down entirely, so changing normal
  /// brightness never happens under HDR content (macOS re-adjusts that content as the
  /// backlight moves, which flickers).
  var level: Double {
    get { UserDefaults.standard.object(forKey: "xdrLevel") as? Double ?? 0 }
    set {
      UserDefaults.standard.set(min(max(newValue, 0), 1), forKey: "xdrLevel")
      sync()
    }
  }

  /// The overlay is up and boosting.
  var isBoosting: Bool { timer != nil }

  private var device: MTLDevice?
  private var queue: MTLCommandQueue?
  private var windows: [NSWindow] = []
  private var multiply: CAMetalLayer?
  private var trigger: CAMetalLayer?
  private var timer: Timer?
  private var current: Double = 1
  /// Ticks the headroom has been gone; short dropouts are ridden out instead of dimming.
  private var dropoutTicks = 0
  /// Headroom seen last tick; while it's still moving, the boost waits.
  private var lastEDR: Double = 0
  /// While normal brightness is changing, macOS reshuffles the headroom; hold the boost.
  private var holdUntil = Date.distantPast

  /// Call when the built-in display's normal brightness changes.
  func noteBrightnessChange() { holdUntil = Date().addingTimeInterval(1.5) }

  /// The boost the slider asks for; independent of how much headroom is open right now,
  /// so changing normal brightness doesn't make it pump.
  private var wanted: Double { 1 + level * 0.48 }
  private var observers: [NSObjectProtocol] = []
  private var screensAsleep = false

  /// The built-in screen, if it has EDR headroom to give.
  static var screen: NSScreen? {
    NSScreen.screens.first {
      let id = $0.displayID ?? 0
      return CGDisplayIsBuiltin(id) != 0 && $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.05
    }
  }

  static var isSupported: Bool { screen != nil }

  func setOn(_ on: Bool) {
    isOn = on
    UserDefaults.standard.set(on, forKey: "xdrOn")
    sync()
  }

  /// Restore the saved state at launch.
  func restore() {
    isOn = UserDefaults.standard.bool(forKey: "xdrOn")
    sync()
  }

  private func sync() {
    let want = isOn && level > 0.005 && Self.screen != nil
    if want, !isBoosting { start() }
    if !want, isBoosting { stop() }
  }

  private func start() {
    guard let screen = Self.screen, let device = MTLCreateSystemDefaultDevice() else { return }
    self.device = device
    queue = device.makeCommandQueue()
    current = 1
    buildWindows(on: screen)

    let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
    observers = [
      nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
        [weak self] _ in
        guard let self, isBoosting else { return }
        guard let s = Self.screen else { return stop() }
        buildWindows(on: s)
      },
      ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
        self?.screensAsleep = true
      },
      ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
        self?.screensAsleep = false
      },
    ]
    timer = Timer.every(0.25, tolerance: 0.05) { [weak self] in self?.tick() }
    tick()
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
    observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
    observers = []
    windows.forEach { $0.orderOut(nil) }
    windows = []
    multiply = nil
    trigger = nil
    queue = nil
    device = nil
  }

  private func buildWindows(on screen: NSScreen) {
    windows.forEach { $0.orderOut(nil) }
    let f = screen.frame
    // One window over the whole screen. (Two halves left a visible seam.)
    let m = makeLayer()
    m.compositingFilter = "multiply"
    multiply = m
    windows = [makeWindow(f, m)]
    let t = makeLayer()
    trigger = t
    windows.append(makeWindow(NSRect(x: f.maxX - 1, y: f.minY, width: 1, height: 1), t))
    // First frame before the windows appear, so there's never an empty one on screen.
    tick()
    windows.forEach { $0.orderFrontRegardless() }
  }

  private func makeLayer() -> CAMetalLayer {
    let l = CAMetalLayer()
    l.device = device
    l.pixelFormat = .rgba16Float
    l.wantsExtendedDynamicRangeContent = true
    l.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
    l.drawableSize = CGSize(width: 2, height: 2)
    l.isOpaque = false
    return l
  }

  private func makeWindow(_ rect: NSRect, _ layer: CAMetalLayer) -> NSWindow {
    let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
    w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.sharingType = .none
    w.isReleasedWhenClosed = false
    // AppKit's default show/hide animation on a full-screen window allocates 90–170 MB of
    // Core Animation commit buffers for a second, and malloc often keeps those pages.
    w.animationBehavior = .none
    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    let v = NSView(frame: NSRect(origin: .zero, size: rect.size))
    v.layer = layer
    v.wantsLayer = true
    w.contentView = v
    return w
  }

  private func tick() {
    guard !screensAsleep, let queue, let screen = Self.screen else { return }
    current = nextFactor(screen)
    guard let cb = queue.makeCommandBuffer() else { return }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    func fill(_ layer: CAMetalLayer, _ value: Double) {
      guard let drawable = layer.nextDrawable() else { return }
      pass.colorAttachments[0].texture = drawable.texture
      pass.colorAttachments[0].clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: 1)
      cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
      cb.present(drawable)
    }
    if let multiply { fill(multiply, current) }
    if let trigger { fill(trigger, 1.8) }
    cb.commit()
  }

  /// Jump straight to the slider's level instead of easing toward it.
  func applyLevelNow() {
    guard isBoosting, let screen = Self.screen else { return }
    let edr = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
    if edr > 1.01 { current = min(wanted, edr) }
    tick()
  }

  /// Boost toward 1 + level × 0.48, capped by the headroom open right now so highlights
  /// don't clip, and eased so changes don't flash. Until macOS opens the headroom (the 1-point
  /// trigger window asks for it), the boost stays at 1.
  private func nextFactor(_ screen: NSScreen) -> Double {
    let edr = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
    let target: Double
    if edr <= 1.01 {
      // macOS briefly reclaims headroom (more so with auto-brightness on). Hold the current
      // boost for up to 3 ticks rather than dipping to the bootstrap value and back.
      dropoutTicks += 1
      if current > 1.1, dropoutTicks <= 3 || Date() < holdUntil { return current }
      lastEDR = edr
      target = 1
    } else {
      dropoutTicks = 0
      // macOS opens (and re-opens) headroom over a few frames while changing the backlight.
      // Moving the boost at the same time doubles the visible change, so wait it out.
      let settling = abs(edr - lastEDR) > edr * 0.05
      lastEDR = edr
      if settling { return current }
      target = min(wanted, edr)
    }
    let gap = target - current
    if abs(gap) < 0.005 { return current } // ignore jitter in the reported headroom
    if gap > 0 { return min(current + 0.03, target) }
    return current + min(gap * 0.25, max(gap, -0.01))
  }
}
