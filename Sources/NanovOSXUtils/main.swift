import AppKit

// `NanovOSXUtils --probe`: print displays, how each is controlled and its level, then exit.
if CommandLine.arguments.contains("--probe") {
  _ = NSApplication.shared
  let b = Brightness()
  b.onChange = {
    guard b.displays.allSatisfy({ d in if case .ddc = d.route { return d.level != nil } else { return true } }) else { return }
    for d in b.displays {
      let route: String
      switch d.route {
      case .system: route = "system"
      case .ddc(let p): route = String(format: "ddc chip=0x%02X uuid=%@", p.chip, p.edidUUID)
      case .software: route = "software (gamma)"
      }
      print(d.id, d.name, route, d.level.map { String(format: "%.0f%%", $0 * 100) } ?? "?")
    }
    exit(0)
  }
  b.onChange?()
  DispatchQueue.main.asyncAfter(deadline: .now() + 5) { print("timeout; partial:", b.displays.map { "\($0.name)=\($0.level ?? -1)" }); exit(1) }
  RunLoop.main.run()
}

// `NanovOSXUtils --render-dashboard out.png [today|week|month]`: draw the dashboard with
// live data into a PNG, then exit.
if let i = CommandLine.arguments.firstIndex(of: "--render-dashboard"), i + 1 < CommandLine.arguments.count {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let args = CommandLine.arguments
  let period: Usage.Period = args.count > i + 2 ? (args[i + 2] == "week" ? .week : args[i + 2] == "month" ? .month : .today) : .today
  let agents = Agents()
  agents.scanProcesses()
  let d = Dashboard(agents: agents, usage: Usage())
  DispatchQueue.main.async { d.render(to: args[i + 1], period: period) { exit(0) } }
  app.run()
}

// `NanovOSXUtils --render-clipboard out.png [preview]`: draw the ⌃V window with sample entries
// (never the real history) into a PNG, then exit.
if let i = CommandLine.arguments.firstIndex(of: "--render-clipboard"), i + 1 < CommandLine.arguments.count {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let path = CommandLine.arguments[i + 1]
  DispatchQueue.main.async {
    let c = Clipboard.sample()
    let p = ClipboardPanel(clipboard: c, appearance: NSAppearance(named: .darkAqua))
    // A drawn stand-in for the image entry's thumbnail.
    let thumb = NSImage(size: NSSize(width: 120, height: 78), flipped: false) { r in
      NSGradient(starting: .systemIndigo, ending: .systemTeal)?.draw(in: r, angle: 35)
      return true
    }
    if let img = c.entries.first(where: { $0.kind == .image }) { p.setSampleThumb(img.id, thumb) }
    p.setSamplePreview(CommandLine.arguments.contains("preview"))
    p.render(to: path)
    exit(0)
  }
  app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// `--bench`: measure the real app through a fixed script, then exit (see Bench.swift).
let bench = CommandLine.arguments.contains("--bench") ? Bench(delegate) : nil
let benchPanel = CommandLine.arguments.contains("--bench-panel") ? Bench(delegate) : nil
if let bench { DispatchQueue.main.async { bench.run() } }
if let benchPanel { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { benchPanel.runPanel() } }
if CommandLine.arguments.contains("--bench-clipboard") {
  let b = Bench(delegate)
  DispatchQueue.main.async { b.runClipboard() }
}
if CommandLine.arguments.contains("--bench-dashboard") {
  let b = Bench(delegate)
  DispatchQueue.main.async { b.runDashboard() }
}
app.run()
