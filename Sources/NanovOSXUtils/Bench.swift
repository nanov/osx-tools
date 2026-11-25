import AppKit

/// `NanovOSXUtils --bench`: runs the real app through a fixed script and prints memory,
/// CPU time and wake-ups per step as tab-separated lines. Restores any setting it touches.
final class Bench {
  private let app: AppDelegate
  private var steps: [(String, TimeInterval, () -> Void)] = []
  private var mark = Bench.sample()

  init(_ app: AppDelegate) { self.app = app }

  struct Sample {
    var footprintMB: Double
    var cpuMs: Double
    var wakeups: UInt64
    var at: Date
  }

  static func sample() -> Sample {
    var vm = task_vm_info_data_t()
    var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &vm) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) }
    }
    var power = task_power_info_data_t()
    var pn = mach_msg_type_number_t(MemoryLayout<task_power_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &power) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(pn)) { task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &pn) }
    }
    return Sample(footprintMB: Double(vm.phys_footprint) / 1_048_576,
                  cpuMs: Double(power.total_user + power.total_system) / 1_000_000,
                  wakeups: power.task_interrupt_wakeups + power.task_platform_idle_wakeups,
                  at: Date())
  }

  /// Record a line: footprint now, and CPU/wake-ups since the previous line.
  private func report(_ name: String) {
    let s = Self.sample()
    let secs = s.at.timeIntervalSince(mark.at)
    print(String(format: "%@\t%.1f MB\tcpu %.1f ms over %.0f s (%.3f%%)\twakeups %.2f/s",
                 name, s.footprintMB, s.cpuMs - mark.cpuMs, secs,
                 (s.cpuMs - mark.cpuMs) / (secs * 10), Double(s.wakeups - mark.wakeups) / secs))
    fflush(stdout)
    mark = s
  }

  private func step(_ name: String, after: TimeInterval, _ action: @escaping () -> Void = {}) {
    steps.append((name, after, action))
  }

  /// `--bench-panel`: open/close the panel in rounds and report footprint, then stay alive
  /// so `leaks`/`heap` can inspect the process.
  func runPanel() {
    var total = 0
    func round(_ n: Int) {
      for _ in 0..<n {
        autoreleasepool { app.togglePanel() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        autoreleasepool { app.togglePanel() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      }
      total += n
      print(String(format: "opens %d\t%.1f MB", total, Self.sample().footprintMB)); fflush(stdout)
    }
    print(String(format: "opens 0\t%.1f MB", Self.sample().footprintMB))
    for n in [1, 9, 20, 30, 40] { round(n) }
    print("ready pid \(getpid())"); fflush(stdout)
  }

  /// `--bench-dashboard`: idle, then the dashboard opened and closed, as on hover.
  func runDashboard() {
    let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
    let f = screen.frame
    let zone = NSRect(x: f.midX - 100, y: f.maxY - 32, width: 200, height: 32)
    let open = { self.app.dashboard.open(on: screen, from: zone, inset: 32) }
    let quick = CommandLine.arguments.contains("--stay")
    step("launch (settled)", after: 5)
    step("idle 60 s, dashboard never opened", after: quick ? 5 : 60)
    step("dashboard open 10 s", after: 10, open)
    step("dashboard closed, 5 s", after: 5) { self.app.dashboard.close() }
    step("idle 60 s after close", after: quick ? 5 : 60)
    step("dashboard opened/closed ×10", after: 5) {
      for _ in 0..<10 {
        open()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        self.app.dashboard.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      }
    }
    step("idle 30 s", after: 30)
    func next(_ i: Int) {
      guard i < steps.count else {
        // `--stay`: keep running so `heap`/`leaks` can look at the process.
        if CommandLine.arguments.contains("--stay") { print("ready pid \(getpid())"); fflush(stdout); return }
        exit(0)
      }
      let (name, after, action) = steps[i]
      action()
      DispatchQueue.main.asyncAfter(deadline: .now() + after) {
        self.report(name)
        next(i + 1)
      }
    }
    next(0)
  }

  /// `--bench-clipboard`: idle with the clipboard watcher running, then the ⌃V window
  /// opened and closed ten times.
  func runClipboard() {
    step("launch (settled)", after: 5)
    step("idle 60 s, clipboard watching", after: CommandLine.arguments.contains("--stay") ? 5 : 60)
    step("clipboard window open 5 s", after: 5) { self.app.toggleClipboard() }
    step("closed, 5 s", after: 5) { self.app.clipboardPanel?.close() }
    step("opened/closed ×10", after: 5) {
      for _ in 0..<10 {
        self.app.toggleClipboard()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        self.app.clipboardPanel?.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      }
    }
    step("idle 30 s", after: 30)
    func next(_ i: Int) {
      guard i < steps.count else {
        if CommandLine.arguments.contains("--stay") { print("ready pid \(getpid())"); fflush(stdout); return }
        exit(0)
      }
      let (name, after, action) = steps[i]
      action()
      DispatchQueue.main.asyncAfter(deadline: .now() + after) {
        self.report(name)
        next(i + 1)
      }
    }
    next(0)
  }

  func run() {
    let d = UserDefaults.standard
    let saved = (d.object(forKey: "xdrOn"), d.object(forKey: "xdrLevel"))
    let ka = app.actions.keepAwake
    let wasAwake = ka.isActive

    step("launch (settled)", after: 5)
    step("idle 60 s", after: 60)
    step("panel open", after: 2) { self.app.togglePanel() }
    step("panel closed", after: 3) { self.app.togglePanel() }
    step("panel opened/closed ×10", after: 3) {
      for _ in 0..<10 { self.app.togglePanel(); self.app.togglePanel() }
    }
    step("idle 30 s after panel use", after: 30)
    step("keep awake on, 10 s", after: 10) { if !wasAwake { ka.start(minutes: nil) } }
    step("keep awake off", after: 2) { if !wasAwake { ka.stop() } }
    step("XDR boost on (≈2%), 30 s", after: 30) {
      self.app.xdr.setOn(true)
      self.app.xdr.level = 0.05
    }
    step("XDR off, 10 s", after: 10) {
      self.app.xdr.level = 0
      self.app.xdr.setOn(false)
    }

    func next(_ i: Int) {
      guard i < steps.count else {
        d.set(saved.0, forKey: "xdrOn")
        d.set(saved.1, forKey: "xdrLevel")
        exit(0)
      }
      let (name, after, action) = steps[i]
      action()
      DispatchQueue.main.asyncAfter(deadline: .now() + after) {
        self.report(name)
        next(i + 1)
      }
    }
    next(0)
  }
}
