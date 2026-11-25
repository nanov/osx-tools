import AppKit

// Built-in and Apple displays: DisplayServices (private, resolved at runtime).
private let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
private let coreDisplayInfo = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)

private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
private typealias InfoFn = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?

private func sym<T>(_ h: UnsafeMutableRawPointer?, _ name: String, _: T.Type) -> T? {
  guard let h, let p = dlsym(h, name) else { return nil }
  return unsafeBitCast(p, to: T.self)
}

private let dsGet = sym(displayServices, "DisplayServicesGetBrightness", GetFn.self)
private let dsSet = sym(displayServices, "DisplayServicesSetBrightness", SetFn.self)
private let dsSmooth = sym(displayServices, "DisplayServicesSetBrightnessSmooth", SetFn.self)
private let cdInfo = sym(coreDisplayInfo, "CoreDisplay_DisplayCreateInfoDictionary", InfoFn.self)

final class Brightness {
  /// system: DisplayServices. ddc: monitor hardware. software: gamma-table dimming, used when
  /// a monitor doesn't answer DDC. macOS restores gamma when the app quits.
  enum Route { case system, ddc(DDCPort), software }

  final class Display {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    fileprivate(set) var route: Route
    /// 0…1; nil until a DDC monitor has answered.
    var level: Double?

    init(id: CGDirectDisplayID, name: String, isBuiltIn: Bool, route: Route) {
      self.id = id
      self.name = name
      self.isBuiltIn = isBuiltIn
      self.route = route
    }
  }

  private(set) var displays: [Display] = []
  var onChange: (() -> Void)?

  /// Serial: DDC I/O blocks for tens of milliseconds and monitors need commands spaced out.
  private let queue = DispatchQueue(label: "brightness.ddc", qos: .userInitiated)
  private let lock = NSLock()
  private var screenObserver: NSObjectProtocol?
  private var wakeObserver: NSObjectProtocol?
  /// Gamma tables as found before we dimmed anything, per display. Never re-read while dimmed,
  /// or each reconnect would compound the dim.
  private var gammaBaseline: [CGDirectDisplayID: [[CGGammaValue]]] = [:]
  private var softwareLevel: [CGDirectDisplayID: Double] = [:]
  /// Software dimming never goes fully black; you'd have no way to see the slider.
  static let softwareFloor = 0.1

  init() {
    rebuild()
    var debounce: DispatchWorkItem?
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      debounce?.cancel()
      let w = DispatchWorkItem { self?.rebuildIfTopologyChanged() }
      debounce = w
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.rebuild() }
    }
  }

  func display(_ id: CGDirectDisplayID) -> Display? { displays.first { $0.id == id } }

  /// Fresh level of a system-route display (the keys may have moved it behind our back).
  func currentLevel(_ d: Display) -> Double? {
    guard case .system = d.route else { return d.level }
    var v: Float = 0
    guard let dsGet, dsGet(d.id, &v) == 0 else { return d.level }
    d.level = Double(v)
    return d.level
  }

  /// Display under the mouse pointer.
  var displayUnderPointer: Display? {
    let p = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
          let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    else { return nil }
    return display(id)
  }

  // MARK: - Topology

  private func rebuildIfTopologyChanged() {
    let ids = Set(activeIDs())
    if ids != Set(displays.map(\.id)) { rebuild() }
  }

  private func activeIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids
  }

  func rebuild() {
    let ids = activeIDs()
    let names = Dictionary(NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
      guard let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
      else { return nil }
      return (id, s.localizedName)
    }, uniquingKeysWith: { a, _ in a })

    var result: [Display] = []
    var needDDC: [CGDirectDisplayID] = []
    for id in ids {
      let builtIn = CGDisplayIsBuiltin(id) != 0
      var v: Float = 0
      if let dsGet, dsGet(id, &v) == 0, (0...1).contains(v) {
        let d = Display(id: id, name: names[id] ?? "Display", isBuiltIn: builtIn, route: .system)
        d.level = Double(v)
        result.append(d)
      } else if !builtIn {
        needDDC.append(id)
      }
    }

    // Match DDC ports to the remaining displays, best score first. The registry walk is
    // skipped when no display needs one.
    let ports = needDDC.isEmpty ? [] : DDCPort.discover()
    var candidates: [(Int, CGDirectDisplayID, Int)] = []
    for id in needDDC {
      let info = (cdInfo?(id)?.takeRetainedValue() as? [String: Any]) ?? [:]
      for (i, p) in ports.enumerated() { candidates.append((p.score(for: id, info: info), id, i)) }
    }
    var usedIDs = Set<CGDirectDisplayID>(), usedPorts = Set<Int>()
    for (s, id, i) in candidates.sorted(by: { $0.0 > $1.0 }) where s > 0 && !usedIDs.contains(id) && !usedPorts.contains(i) {
      usedIDs.insert(id)
      usedPorts.insert(i)
      result.append(Display(id: id, name: names[id] ?? "Display", isBuiltIn: false, route: .ddc(ports[i])))
    }
    // One unmatched display and one unmatched port: they belong together.
    let leftIDs = needDDC.filter { !usedIDs.contains($0) }
    let leftPorts = ports.indices.filter { !usedPorts.contains($0) }
    if leftIDs.count == 1, leftPorts.count == 1 {
      result.append(Display(id: leftIDs[0], name: names[leftIDs[0]] ?? "Display", isBuiltIn: false,
                            route: .ddc(ports[leftPorts[0]])))
      usedIDs.insert(leftIDs[0])
    }
    for id in needDDC where !usedIDs.contains(id) {
      let d = Display(id: id, name: names[id] ?? "Display", isBuiltIn: false, route: .software)
      d.level = softwareLevel[id] ?? 1
      result.append(d)
    }

    // Keep screen order: built-in first, then left to right.
    let order = ids.enumerated().reduce(into: [CGDirectDisplayID: Int]()) { $0[$1.element] = $1.offset }
    displays = result.sorted { ($0.isBuiltIn ? -1 : order[$0.id] ?? 0) < ($1.isBuiltIn ? -1 : order[$1.id] ?? 0) }
    onChange?()
    for d in displays {
      if case .ddc = d.route { read(d) }
      if case .software = d.route, let l = d.level, l < 1 { applyGamma(d.id, l) }
    }
  }

  // MARK: - Reading

  /// Re-read levels; DDC monitors are asked again (their own buttons may have changed them).
  func refresh() {
    for d in displays {
      switch d.route {
      case .system:
        var v: Float = 0
        if CGDisplayIsAsleep(d.id) == 0, let dsGet, dsGet(d.id, &v) == 0 { d.level = Double(v) }
      case .ddc: read(d)
      case .software: break
      }
    }
    onChange?()
  }

  private func read(_ d: Display) {
    guard case .ddc(let port) = d.route else { return }
    queue.async { [weak self] in
      guard let self else { return }
      guard let st = readState(d.id, port) else {
        DispatchQueue.main.async { self.fallBackToSoftware(d) }
        return
      }
      publish(d, Double(st.cur) / Double(st.max), max: st.max, step: false)
    }
  }

  // MARK: - Writing

  /// Called on main after a key/shortcut step lands, with the new level (for the OSD).
  var onStep: ((Display, Double) -> Void)?

  // DDC state is owned by `queue`; requests are merged under `lock` and drained there.
  private struct DDCState { var cur: UInt16; var max: UInt16; var readAt: Date }
  private var ddc: [CGDirectDisplayID: DDCState] = [:]
  private var wantLevel: [CGDirectDisplayID: Double] = [:]
  private var wantSteps: [CGDirectDisplayID: (count: Int, unit: Double)] = [:]
  private var draining: Set<CGDirectDisplayID> = []

  /// Absolute level (slider). Intermediate drag values are dropped; only the latest is sent.
  func set(_ d: Display, _ level: Double) {
    let level = min(max(level, 0), 1)
    switch d.route {
    case .system:
      _ = dsSet?(d.id, Float(level))
      d.level = level
    case .ddc(let port):
      d.level = level
      lock.lock()
      wantLevel[d.id] = level
      wantSteps[d.id] = nil
      lock.unlock()
      scheduleDrain(d, port)
    case .software:
      let l = max(level, Self.softwareFloor)
      d.level = l
      softwareLevel[d.id] = l
      applyGamma(d.id, l)
    }
  }

  /// Step by ±`unit` (e.g. 1/16). Steps that pile up while the monitor is busy are merged
  /// into one write, so holding the key never lags behind.
  func step(_ d: Display, up: Bool, unit: Double) {
    switch d.route {
    case .system:
      var v: Float = 0
      guard let dsGet, dsGet(d.id, &v) == 0 else { return }
      let target = Self.snap(Double(v), steps: up ? 1 : -1, unit: unit)
      _ = dsSmooth?(d.id, Float(target) - v) ?? dsSet?(d.id, Float(target))
      d.level = target
      onChange?()
      onStep?(d, target)
    case .ddc(let port):
      lock.lock()
      let prev = wantSteps[d.id]?.count ?? 0
      wantSteps[d.id] = (prev + (up ? 1 : -1), unit)
      lock.unlock()
      scheduleDrain(d, port)
    case .software:
      let target = max(Self.snap(d.level ?? 1, steps: up ? 1 : -1, unit: unit), Self.softwareFloor)
      set(d, target)
      onChange?()
      onStep?(d, target)
    }
  }

  private func scheduleDrain(_ d: Display, _ port: DDCPort) {
    lock.lock()
    let start = draining.insert(d.id).inserted
    lock.unlock()
    guard start else { return }
    queue.async { [weak self] in self?.drain(d, port) }
  }

  private func drain(_ d: Display, _ port: DDCPort) {
    lock.lock()
    let level = wantLevel.removeValue(forKey: d.id)
    let steps = wantSteps.removeValue(forKey: d.id)
    draining.remove(d.id)
    lock.unlock()

    var target: Double
    var max: UInt16
    if let level {
      max = ddc[d.id]?.max ?? readState(d.id, port)?.max ?? 100
      target = level
    } else if let steps {
      // A level older than 3 s is re-read: the monitor's buttons may have moved it.
      let fresh = ddc[d.id].flatMap { Date().timeIntervalSince($0.readAt) < 3 ? $0 : nil }
      guard let st = fresh ?? readState(d.id, port) else { return }
      max = st.max
      target = Self.snap(Double(st.cur) / Double(st.max), steps: steps.count, unit: steps.unit)
    } else {
      return
    }
    let raw = UInt16((target * Double(max)).rounded())
    guard port.set(.luminance, raw) else {
      DispatchQueue.main.async { self.fallBackToSoftware(d) }
      return
    }
    ddc[d.id] = DDCState(cur: raw, max: max, readAt: Date())
    publish(d, target, max: max, step: steps != nil)
  }

  private func readState(_ id: CGDirectDisplayID, _ port: DDCPort) -> DDCState? {
    guard let (cur, max) = port.get(.luminance) else { return nil }
    let st = DDCState(cur: cur, max: max, readAt: Date())
    ddc[id] = st
    return st
  }

  private func publish(_ d: Display, _ level: Double, max: UInt16, step: Bool) {
    DispatchQueue.main.async { [weak self] in
      d.level = level
      self?.onChange?()
      if step { self?.onStep?(d, level) }
    }
  }

  // MARK: - Software dimming

  private func fallBackToSoftware(_ d: Display) {
    guard case .ddc = d.route else { return }
    d.route = .software
    d.level = softwareLevel[d.id] ?? 1
    onChange?()
  }

  private func applyGamma(_ id: CGDirectDisplayID, _ level: Double) {
    if gammaBaseline[id] == nil {
      let cap = CGDisplayGammaTableCapacity(id)
      var r = [CGGammaValue](repeating: 0, count: Int(cap)), g = r, b = r
      var n: UInt32 = 0
      guard CGGetDisplayTransferByTable(id, cap, &r, &g, &b, &n) == .success, n > 0 else { return }
      gammaBaseline[id] = [Array(r[..<Int(n)]), Array(g[..<Int(n)]), Array(b[..<Int(n)])]
    }
    guard let base = gammaBaseline[id] else { return }
    let f = CGGammaValue(level)
    let r = base[0].map { $0 * f }, g = base[1].map { $0 * f }, b = base[2].map { $0 * f }
    CGSetDisplayTransferByTable(id, UInt32(r.count), r, g, b)
  }

  /// Move `steps` units from `cur`, snapping to the unit grid so presses land on clean values.
  private static func snap(_ cur: Double, steps: Int, unit: Double) -> Double {
    let base = (cur / unit).rounded()
    return min(max((base + Double(steps)) * unit, 0), 1)
  }
}
