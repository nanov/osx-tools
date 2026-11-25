import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  let actions = Actions()
  private var watcher: ConfigWatcher?
  private var problems: [String] = []
  private(set) lazy var panel = PanelController { [unowned self] p in sections(p) }
  private let brightness = Brightness()
  private lazy var brightnessKeys = BrightnessKeys(brightness: brightness)
  private let osd = OSD()
  let xdr = ExtraBrightness()
  private let agents = Agents()
  private let usage = Usage()
  private(set) lazy var dashboard = Dashboard(agents: agents, usage: usage)
  private lazy var island = Island(agents: agents, dashboard: dashboard)
  let clipboard = Clipboard()
  /// The ⌃V window, only while it's open.
  private(set) var clipboardPanel: ClipboardPanel?
  /// Live controls of the open panel's display rows, updated in place on brightness changes.
  private var displayRows: [CGDirectDisplayID: (slider: NSSlider, value: NSTextField)] = [:]

  func applicationDidFinishLaunching(_ note: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.target = self
    statusItem.button?.action = #selector(togglePanel)
    updateIcon()

    actions.keepAwake.onChange = { [weak self] in
      self?.updateIcon()
      self?.panel.refresh()
    }
    brightness.onChange = { [weak self] in self?.brightnessChanged() }
    brightness.onStep = { [weak self] d, level in
      if !d.isBuiltIn { self?.osd.show(level: level, on: d.id) }
    }
    if !AX.trusted { AX.promptIfNeeded() }
    brightnessKeys.onSystemBrightnessKey = { [weak self] in self?.xdr.noteBrightnessChange() }
    brightnessKeys.onBuiltInKey = { [weak self] up, unit in self?.boostKey(up: up, unit: unit) ?? false }
    brightnessKeys.start()
    xdr.restore()
    agents.onChange = { [weak self] in
      self?.island.update()
      self?.panel.refresh()
    }
    agents.onTranscript = { [weak self] in self?.usage.noteTranscript($0) }
    agents.start()
    agents.scanProcesses()
    island.update() // hover zones exist from launch, with or without sessions
    actions.onClipboard = { [weak self] plain in plain ? self?.clipboard.pastePlain() : self?.toggleClipboard() }
    clipboard.start()
    reload()
    watcher = ConfigWatcher { [weak self] in self?.reload() }
  }

  func toggleClipboard() {
    if let p = clipboardPanel { return p.close() }
    clipboard.check() // a copy made just now is in the list
    let p = ClipboardPanel(clipboard: clipboard)
    p.onClose = { [weak self] in self?.clipboardPanel = nil }
    clipboardPanel = p
    p.show()
  }

  /// The Claude logo, taken from the installed Claude app's menu-bar icon (not shipped with
  /// this app); the sparkle symbol when Claude.app isn't there.
  static func claudeIcon(color: NSColor) -> NSImageView {
    let path = "/Applications/Claude.app/Contents/Resources/TrayIconTemplate.png"
    guard let image = NSImage(contentsOfFile: path) else { return PanelController.icon("sparkle", color: color) }
    image.isTemplate = true
    return trayIcon(image, color: color)
  }

  /// Cursor's menu-bar icon, from the installed app (not shipped with this one).
  static func cursorIcon(color: NSColor) -> NSImageView {
    guard let image = Agents.cursorIcon?.copy() as? NSImage else { return PanelController.icon("cube", color: color) }
    return trayIcon(image, color: color)
  }

  private static func trayIcon(_ image: NSImage, color: NSColor) -> NSImageView {
    image.size = NSSize(width: 16, height: 16)
    let v = NSImageView(image: image)
    v.contentTintColor = color
    v.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([v.widthAnchor.constraint(equalToConstant: 16), v.heightAnchor.constraint(equalToConstant: 16)])
    return v
  }

  @objc func togglePanel() {
    guard let button = statusItem.button else { return }
    panel.toggle(below: button)
    if panel.isOpen {
      brightness.refresh()
      if !brightnessKeys.isRunning { brightnessKeys.start() } // Accessibility may have been granted since
    } else {
      displayRows.removeAll()
    }
  }

  private func brightnessChanged() {
    guard panel.isOpen else { return }
    if Set(displayRows.keys) != Set(brightness.displays.map(\.id)) { return panel.refresh() }
    let dragging = NSEvent.pressedMouseButtons != 0
    for d in brightness.displays {
      guard let row = displayRows[d.id], let v = sliderValue(d) else { continue }
      if !dragging { row.slider.doubleValue = v }
      row.value.stringValue = valueText(d)
    }
  }

  private static func percent(_ l: Double) -> String { "\(Int((l * 100).rounded()))%" }

  // MARK: - Brightness above 100% (XDR)
  //
  // With Extra Brightness on, the built-in display's slider and keys continue past 100% into
  // the boost. Normal brightness only moves while the boost is at 0, i.e. while no HDR overlay
  // is on screen: macOS re-adjusts HDR content as the backlight changes, which flickers.

  private func extendsPast100(_ d: Brightness.Display) -> Bool { d.isBuiltIn && xdr.isOn }

  /// 0…1 is normal brightness; 1…2 is the boost on top of 100%.
  private func sliderValue(_ d: Brightness.Display) -> Double? {
    guard let l = d.level else { return nil }
    return extendsPast100(d) && xdr.level > 0 ? 1 + xdr.level : l
  }

  private func valueText(_ d: Brightness.Display) -> String {
    guard let l = d.level else { return "…" }
    if extendsPast100(d), xdr.level > 0 { return "100% + \(Int((xdr.level * 48).rounded()))%" }
    return Self.percent(l)
  }

  /// Brightness key on the built-in display. With Extra Brightness on we take the key: one
  /// scale of 16 normal steps then 8 boost steps (×4 with ⌥⇧), shown on one indicator bar.
  /// Returns false (key goes to macOS) when Extra Brightness is off.
  private func boostKey(up: Bool, unit: Double) -> Bool {
    guard xdr.isOn, let d = brightness.displays.first(where: \.isBuiltIn) else { return false }
    let boostStep = unit * 2 // 1/8 of the boost per press, 1/32 with ⌥⇧
    let sdr = brightness.currentLevel(d) ?? 0
    let snapped = (xdr.level / boostStep).rounded() * boostStep
    if up {
      if sdr < 0.999 { brightness.step(d, up: true, unit: unit) } else { xdr.level = min(1, snapped + boostStep) }
    } else {
      if xdr.level > 0 { xdr.level = max(0, snapped - boostStep) } else { brightness.step(d, up: false, unit: unit) }
    }
    xdr.applyLevelNow()

    let sdrSteps = Int((1 / unit).rounded()), boostSteps = Int((1 / boostStep).rounded())
    let nowSDR = brightness.currentLevel(d) ?? sdr
    let filled = Int((nowSDR * Double(sdrSteps)).rounded()) + Int((xdr.level * Double(boostSteps)).rounded())
    osd.show(level: Double(filled) / Double(sdrSteps + boostSteps), on: d.id)
    brightnessChanged()
    return true
  }

  private func updateIcon() {
    let awake = actions.keepAwake.isActive
    statusItem.button?.image = NSImage(systemSymbolName: awake ? "cup.and.heat.waves.fill" : "command",
                                       accessibilityDescription: "Nanov OSX Tools")
  }

  private func reload() {
    let config: Config
    do {
      config = try Config.load()
    } catch {
      problems = ["Config error, kept previous shortcuts: \(error)"]
      panel.refresh()
      return
    }
    HotKeys.shared.unregisterAll()
    var bindings = config.bindings.map { ($0.keys, $0.action) }
    for (keys, action) in Config.implicit where !bindings.contains(where: { "\($0.1)" == "\(action)" }) {
      bindings.append((keys, action))
    }
    // The clipboard's shortcuts are free for other apps while it's off.
    if !clipboard.isEnabled {
      bindings.removeAll { if case .clipboardHistory = $0.1 { return true }; if case .pastePlain = $0.1 { return true }; return false }
    }
    problems = bindings.compactMap { keys, action in
      HotKeys.shared.register(keys) { [weak self] in self?.actions.run(action) }
    }
    panel.refresh()
  }

  // MARK: - Panel contents

  private func sections(_ p: PanelController) -> [NSView] {
    var out: [NSView] = [header(p)]
    if !AX.trusted {
      let b = p.on(NSButton(title: "Grant Accessibility Access…", target: nil, action: nil)) { _ in
        AX.promptIfNeeded()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
      }
      out.append(PanelController.card([
        label("Window shortcuts need Accessibility access.", size: 12, color: .secondaryLabelColor), b,
      ]))
    }
    if !problems.isEmpty {
      out.append(PanelController.card(problems.map {
        let l = label("⚠︎ " + $0, size: 11, color: .systemOrange)
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 3
        return l
      }))
    }
    out.append(displaysCard(p))
    out.append(keepAwakeCard(p))
    out.append(claudeCard(p))
    if Agents.cursorInstalled { out.append(cursorCard(p)) }
    out.append(clipboardCard(p))
    out.append(footer(p))
    return out
  }

  private func header(_ p: PanelController) -> NSView {
    let edit = p.on(PanelController.iconButton("square.and.pencil", tip: "Edit Config")) { _ in
      NSWorkspace.shared.open(Config.url)
    }
    let reload = p.on(PanelController.iconButton("arrow.clockwise", tip: "Reload Config")) { [weak self] _ in
      self?.reload()
    }
    return PanelController.row([
      label("Nanov OSX Tools", weight: .semibold), PanelController.spacer(), edit, reload,
    ])
  }

  private func displaysCard(_ p: PanelController) -> NSView {
    displayRows.removeAll()
    var rows: [NSView] = []
    for d in brightness.displays {
      let value = label(valueText(d), size: 11, color: .secondaryLabelColor)
      value.alignment = .right
      var title: [NSView] = [
        PanelController.icon(d.isBuiltIn ? "laptopcomputer" : "display", color: .secondaryLabelColor),
        label(d.name, size: 12, weight: .medium),
      ]
      if case .software = d.route {
        let tag = label("software", size: 10, color: .tertiaryLabelColor)
        tag.toolTip = "This monitor doesn't answer DDC, so it's dimmed through its gamma table."
        title.append(tag)
      }
      title += [PanelController.spacer(), value]

      let extended = extendsPast100(d)
      let slider = p.on(NSSlider(value: sliderValue(d) ?? 0, minValue: 0, maxValue: extended ? 2 : 1,
                                 target: nil, action: nil)) { [weak self] s in
        guard let self, let d = brightness.display(d.id) else { return }
        let v = s.doubleValue
        if extendsPast100(d), v > 1 {
          if (d.level ?? 0) < 0.999 { brightness.set(d, 1) }
          xdr.level = v - 1
          xdr.applyLevelNow()
        } else {
          if xdr.level > 0 { xdr.level = 0 }
          if d.isBuiltIn { xdr.noteBrightnessChange() }
          brightness.set(d, min(v, 1))
        }
        displayRows[d.id]?.value.stringValue = valueText(d)
      }
      if extended {
        slider.numberOfTickMarks = 3 // marks 0, 100% and the top of the boost
        slider.allowsTickMarkValuesOnly = false
      }
      slider.isContinuous = true
      slider.controlSize = .small
      slider.isEnabled = d.level != nil
      displayRows[d.id] = (slider, value)
      rows.append(PanelController.row(title, spacing: 6))
      rows.append(slider)
      if d.isBuiltIn, ExtraBrightness.isSupported { rows += xdrRows(p) }
    }
    return PanelController.card(rows)
  }

  private func xdrRows(_ p: PanelController) -> [NSView] {
    let toggle = p.on(NSSwitch()) { [weak self] sw in
      self?.xdr.setOn(sw.state == .on)
      self?.panel.refresh()
    }
    toggle.state = xdr.isOn ? .on : .off
    toggle.controlSize = .mini
    let title = PanelController.row([
      PanelController.icon("sun.max.circle.fill", color: xdr.isBoosting ? .systemYellow : .secondaryLabelColor),
      label("Extra Brightness (XDR)", size: 11, color: .secondaryLabelColor),
      PanelController.spacer(), toggle,
    ], spacing: 6)
    title.toolTip = "Lets the slider and brightness keys go past 100% using the display's HDR headroom."
    return [title]
  }

  private static let durations: [(String, Int?)] = [
    ("15m", 15), ("30m", 30), ("1h", 60), ("2h", 120), ("4h", 240), ("∞", nil),
  ]

  private func keepAwakeCard(_ p: PanelController) -> NSView {
    let ka = actions.keepAwake
    var status = "Off"
    if ka.isActive {
      status = ka.endDate.map { "Until " + $0.formatted(date: .omitted, time: .shortened) } ?? "On"
    }
    let toggle = p.on(NSSwitch()) { [weak self] sw in
      guard let ka = self?.actions.keepAwake else { return }
      sw.state == .on ? ka.start(minutes: ka.lastMinutes) : ka.stop()
    }
    toggle.state = ka.isActive ? .on : .off
    toggle.controlSize = .small

    let title = PanelController.row([
      PanelController.icon("cup.and.heat.waves.fill", color: ka.isActive ? .controlAccentColor : .secondaryLabelColor),
      label("Keep Awake", weight: .medium),
      PanelController.spacer(),
      label(status, size: 11, color: .secondaryLabelColor),
      toggle,
    ])

    let seg = p.on(NSSegmentedControl(labels: Self.durations.map(\.0), trackingMode: .selectOne, target: nil, action: nil)) {
      [weak self] s in
      guard let ka = self?.actions.keepAwake else { return }
      let m = Self.durations[s.selectedSegment].1
      ka.lastMinutes = m
      ka.start(minutes: m)
    }
    seg.controlSize = .small
    seg.segmentDistribution = .fillEqually
    let shown = ka.isActive ? ka.minutes : ka.lastMinutes
    seg.selectedSegment = Self.durations.firstIndex { $0.1 == shown } ?? Self.durations.count - 1

    let display = p.on(NSButton(checkboxWithTitle: "Keep display on", target: nil, action: nil)) { [weak self] b in
      self?.actions.keepAwake.keepDisplayOn = b.state == .on
    }
    display.state = ka.keepDisplayOn ? .on : .off
    display.controlSize = .small
    display.font = .systemFont(ofSize: 11)

    return PanelController.card([title, seg, display])
  }

  private func claudeCard(_ p: PanelController) -> NSView {
    let installed = Agents.hooksInstalled
    let active = agents.sessions.values.filter { $0.source == .claude && $0.state != .done }.count
    let status = !installed ? "Off" : active == 0 ? "Idle" : "\(active) active"
    let button = p.on(NSButton(title: installed ? "Remove Hooks" : "Install Hooks", target: nil, action: nil)) {
      [weak self] _ in
      do {
        try installed ? Agents.removeHooks() : Agents.installHooks()
      } catch {
        self?.problems.append("Claude Code hooks: \(error.localizedDescription)")
      }
      self?.panel.refresh()
    }
    button.controlSize = .small
    button.toolTip = installed
      ? "Removes this app's hooks from ~/.claude/settings.json."
      : "Adds hooks to ~/.claude/settings.json so Claude Code reports its status to the island. New sessions pick them up."
    var extra: [NSView] = []
    if let problem = agents.jumpProblem {
      let l = label("⚠︎ " + problem, size: 11, color: .systemOrange)
      l.lineBreakMode = .byWordWrapping
      l.maximumNumberOfLines = 2
      extra.append(l)
    }
    return PanelController.card([PanelController.row([
      Self.claudeIcon(color: active > 0 ? .systemOrange : .secondaryLabelColor),
      label("Claude Code", weight: .medium),
      PanelController.spacer(),
      label(status, size: 11, color: .secondaryLabelColor),
      button,
    ])] + extra)
  }

  private func cursorCard(_ p: PanelController) -> NSView {
    let installed = Agents.cursorHooksInstalled()
    let active = agents.sessions.values.filter { $0.source == .cursor && $0.state != .done }.count
    let status = !installed ? "Off" : active == 0 ? "Idle" : "\(active) active"
    let button = p.on(NSButton(title: installed ? "Remove Hooks" : "Install Hooks", target: nil, action: nil)) {
      [weak self] _ in
      do {
        try installed ? Agents.removeCursorHooks() : Agents.installCursorHooks()
      } catch {
        self?.problems.append("Cursor hooks: \(error.localizedDescription)")
      }
      self?.panel.refresh()
    }
    button.controlSize = .small
    button.toolTip = installed
      ? "Removes this app's hooks from ~/.cursor/hooks.json."
      : "Adds hooks to ~/.cursor/hooks.json so Cursor's agent reports its status to the island. Cursor reloads them by itself."
    return PanelController.card([PanelController.row([
      Self.cursorIcon(color: active > 0 ? .labelColor : .secondaryLabelColor),
      label("Cursor", weight: .medium),
      PanelController.spacer(),
      label(status, size: 11, color: .secondaryLabelColor),
      button,
    ])])
  }

  private func clipboardCard(_ p: PanelController) -> NSView {
    let on = clipboard.isEnabled
    let toggle = p.on(NSSwitch()) { [weak self] sw in
      self?.clipboard.isEnabled = sw.state == .on
      self?.reload() // registers or frees ⌃V
    }
    toggle.state = on ? .on : .off
    toggle.controlSize = .small
    let count = clipboard.entries.count
    let clear = p.on(NSButton(title: "Clear History", target: nil, action: nil)) { [weak self] _ in
      self?.clipboard.clearRecent()
      self?.panel.refresh()
    }
    clear.controlSize = .small
    clear.toolTip = "Removes everything but pinned entries."
    clear.isEnabled = clipboard.entries.contains { !$0.pinned }
    return PanelController.card([
      PanelController.row([
        PanelController.icon("doc.on.clipboard", color: on ? .controlAccentColor : .secondaryLabelColor),
        label("Clipboard", weight: .medium),
        PanelController.spacer(),
        label(on ? "⌃V · \(count) items" : "Off", size: 11, color: .secondaryLabelColor),
        toggle,
      ]),
      PanelController.row([PanelController.spacer(), clear]),
    ])
  }

  private func footer(_ p: PanelController) -> NSView {
    let login = p.on(NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)) { [weak self] b in
      let svc = SMAppService.mainApp
      do {
        if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
      } catch {
        self?.problems.append("Launch at Login: \(error.localizedDescription)")
        self?.panel.refresh()
      }
      b.state = svc.status == .enabled ? .on : .off
    }
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    login.controlSize = .small
    login.font = .systemFont(ofSize: 11)
    let capture = p.on(NSButton(checkboxWithTitle: "Show island in screenshots", target: nil, action: nil)) { [weak self] b in
      UserDefaults.standard.set(b.state == .on, forKey: "allowScreenCapture")
      self?.island.applySharing()
    }
    capture.state = UserDefaults.standard.bool(forKey: "allowScreenCapture") ? .on : .off
    capture.controlSize = .small
    capture.font = .systemFont(ofSize: 11)
    let quit = p.on(NSButton(title: "Quit", target: nil, action: nil)) { _ in NSApp.terminate(nil) }
    quit.controlSize = .small
    quit.bezelStyle = .push
    let stack = NSStackView(views: [PanelController.row([login, PanelController.spacer(), quit]),
                                    PanelController.row([capture, PanelController.spacer()])])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    return stack
  }
}
