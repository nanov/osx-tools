import AppKit

/// The Claude Code dashboard that grows out of the notch (or the top-centre pill) on hover:
/// account and five-hour block, API-value spending, live sessions, trend, top models and
/// projects, and a 13-week activity grid.
///
/// Its window and views exist only while it's open. The black silhouette is a shape layer
/// whose path follows a spring, sampled into keyframes once per opening, so the motion runs
/// in the window server. Bars and grid cells are plain CALayers with a background colour,
/// so they cost no backing store.
final class Dashboard {
  private let agents: Agents
  private let usage: Usage
  private var window: DashboardWindow?
  private var root: RootView?
  private var scroll: NSScrollView?
  private var period = Usage.Period.today
  /// Kept between openings so the next one starts with numbers instead of a blank.
  private var summary: Usage.Summary?
  private var account = Account()
  private var accountStamp: Date?
  /// Plan limits from the `claude` CLI; made on first opening.
  private lazy var limits: Limits = {
    let l = Limits()
    l.onChange = { [weak self] in if self?.isOpen == true { self?.build() } }
    return l
  }()
  private var clock: Timer?
  private var tickers: [() -> Void] = []
  private var monitors: [Any] = []
  private var closeWork: DispatchWorkItem?
  private var zone = NSRect.zero
  private var screenFrame = NSRect.zero
  private weak var screen: NSScreen?
  private var maxHeight: CGFloat = 600
  private var topInset: CGFloat = 0
  /// Height of the open silhouette.
  private var height: CGFloat = 0

  static let width: CGFloat = 520

  var isOpen: Bool { window != nil }

  init(agents: Agents, usage: Usage) {
    self.agents = agents
    self.usage = usage
    usage.onChange = { [weak self] in self?.dataChanged() }
  }

  // MARK: - Open / close

  /// Opens below `zone` (the notch or pill, in screen coordinates). `inset` is the height
  /// of the menu bar band the panel covers before its content starts.
  func open(on screen: NSScreen, from zone: NSRect, inset: CGFloat) {
    closeWork?.cancel()
    if isOpen { return }
    self.zone = zone
    agents.scanProcesses()
    screenFrame = screen.frame
    self.screen = screen
    topInset = inset
    // About three quarters of the screen; the cards scroll inside that.
    maxHeight = (screen.visibleFrame.height * 0.75).rounded() + inset
    let w = DashboardWindow()
    let root = RootView(frame: NSRect(x: 0, y: 0, width: Silhouette.envelopeWidth(Self.width), height: 400))
    root.onEnter = { [weak self] in self?.closeWork?.cancel() }
    root.onExit = { [weak self] in self?.scheduleClose() }
    w.contentView = root
    window = w
    self.root = root
    build()
    w.orderFrontRegardless()
    root.grow(from: zone.size, opening: true, done: nil)

    monitors = [
      NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() },
      NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in if e.keyCode == 53 { self?.close() } },
    ].compactMap { $0 }
    clock = Timer.every(1, tolerance: 0.2) { [weak self] in self?.tickers.forEach { $0() } }

    usage.refresh()
    usage.summary(period) { [weak self] s in self?.summaryArrived(s) }
    readAccount()
    limits.refreshIfStale()
  }

  /// The opening in reverse: the content fades, the silhouette shrinks back into the notch.
  func close() {
    closeWork?.cancel()
    guard let w = window, let root else { return }
    clock?.invalidate()
    clock = nil
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    tickers = []
    limits.cancel()
    window = nil
    self.root = nil
    scroll = nil
    w.ignoresMouseEvents = true // the menu bar under it works again at once
    root.grow(from: zone.size, opening: false) {
      w.orderOut(nil)
      w.contentView = nil
      // Hand the pages the views used back to the system instead of keeping them for
      // the next opening.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { malloc_zone_pressure_relief(nil, 0) }
    }
  }

  private func scheduleClose() {
    closeWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.close() }
    closeWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
  }

  // MARK: - Updates

  func sessionsChanged() { if isOpen { build() } }

  private func dataChanged() {
    guard isOpen else { return }
    if usage.progress != nil { return build() } // first read: just move the progress along
    usage.summary(period) { [weak self] s in self?.summaryArrived(s) }
  }

  private func summaryArrived(_ s: Usage.Summary) {
    guard isOpen, s.period == period else { return }
    summary = s
    build()
  }

  private func select(_ p: Usage.Period) {
    guard p != period else { return }
    period = p
    usage.summary(p) { [weak self] s in self?.summaryArrived(s) }
  }

  private func readAccount() {
    let path = NSHomeDirectory() + "/.claude.json"
    let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    guard stamp != accountStamp else { return }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let a = Account.read(path)
      DispatchQueue.main.async {
        guard let self else { return }
        self.account = a
        self.accountStamp = stamp
        if self.isOpen { self.build() }
      }
    }
  }

  // MARK: - Layout

  private static let margin: CGFloat = 10
  private static let gap: CGFloat = 10
  private static var half: CGFloat { (width - 2 * margin - gap) / 2 }
  private static var full: CGFloat { width - 2 * margin }

  /// (Re)builds every card from current state and resizes the window to fit. The period
  /// row stays put; the cards scroll below it.
  private func build() {
    guard let root, let window else { return }
    tickers = []
    let keptOffset = scroll?.contentView.bounds.origin.y ?? 0
    root.content.subviews.forEach { $0.removeFromSuperview() }
    let m = Self.margin

    let header = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.width, height: topInset + 34))
    let periodRow = periodSwitch()
    periodRow.frame.origin = NSPoint(x: m + 2, y: topInset + 4)
    header.addSubview(periodRow)
    // The name left of the notch (or the pill), the version right of it, in the camera band.
    if zone.width > 0 {
      // The camera housing itself, not the strip around it (which widens while sessions run).
      var gap = zone.width
      if let screen, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea { gap = r.minX - l.maxX }
      let left = Self.width / 2 + zone.midX - screenFrame.midX - gap / 2 - 10
      let right = left + gap + 20
      let midY = min(zone.height, topInset) / 2
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
      for (text, leading) in [("Nanov OSX Tools", false), (version, true)] {
        let l = label(text, size: 11, weight: leading ? .medium : .semibold, color: leading ? Style.grey : Style.grey5)
        // Both hug the notch: the name ends at its left side, the version starts at its right.
        let x = leading ? right : left - l.frame.width
        l.frame.origin = NSPoint(x: x, y: midY - l.frame.height / 2)
        header.addSubview(l)
      }
    }
    if let p = usage.progress ?? (summary == nil ? 0 : nil) {
      let l = label("Reading history… \(Int(p * 100))%", size: 10.5, weight: .medium, color: Style.grey)
      l.frame.origin = NSPoint(x: Self.width - m - 2 - l.frame.width, y: topInset + 4 + (22 - l.frame.height) / 2)
      header.addSubview(l)
    }

    let doc = FlippedView()
    var y: CGFloat = 0
    func place(_ v: NSView, x: CGFloat = m) { v.frame.origin = NSPoint(x: x, y: y); doc.addSubview(v) }

    let accountCard = accountCard()
    place(accountCard)
    let rowHeight = accountCard.frame.height
    place(summary.map { spendingCard($0, height: rowHeight) } ?? progressCard(height: rowHeight), x: m + Self.half + Self.gap)
    y += accountCard.frame.height + Self.gap

    let now = nowCard()
    place(now)
    y += now.frame.height + Self.gap

    if let s = summary {
      let trend = trendCard(s)
      place(trend)
      y += trend.frame.height + Self.gap
      let models = rankCard(symbol: "cpu", title: "Models", rows: s.models, color: Style.accentBar)
      place(models)
      place(rankCard(symbol: "folder", title: "Projects", rows: s.projects, color: Style.white),
            x: m + Self.half + Self.gap)
      y += models.frame.height + Self.gap
      let activity = activityCard(s)
      place(activity)
      y += activity.frame.height + Self.gap
    }
    doc.frame = NSRect(x: 0, y: 0, width: Self.width, height: y)

    height = min(header.frame.height + y, maxHeight)
    let scroll = FadingScrollView(frame: NSRect(x: 0, y: header.frame.height, width: Self.width,
                                                height: height - header.frame.height))
    scroll.documentView = doc
    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(keptOffset, max(0, y - scroll.frame.height))))
    scroll.reflectScrolledClipView(scroll.contentView)
    scroll.updateFade()
    root.content.addSubview(header)
    root.content.addSubview(scroll)
    self.scroll = scroll

    let size = NSSize(width: Silhouette.envelopeWidth(Self.width), height: height + Silhouette.overshoot)
    let frame = NSRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
                       width: size.width, height: size.height)
    if window.frame != frame {
      window.setFrame(frame, display: false)
      root.frame = NSRect(origin: .zero, size: frame.size)
    }
    root.layoutContent(bodyWidth: Self.width, height: height)
  }

  // MARK: Period switch

  private func periodSwitch() -> NSView {
    let v = FlippedView()
    var x: CGFloat = 0
    for (p, title) in [(Usage.Period.today, "Today"), (.week, "7 days"), (.month, "30 days")] {
      let selected = p == period
      let b = Pressable()
      let l = label(title, size: 11, weight: .semibold, color: selected ? Style.white : Style.grey)
      b.frame = NSRect(x: x, y: 0, width: l.frame.width + 20, height: 22)
      l.frame.origin = NSPoint(x: 10, y: (22 - l.frame.height) / 2)
      b.addSubview(l)
      b.wantsLayer = true
      b.layer?.cornerRadius = 11
      b.layer?.backgroundColor = selected ? Style.chip.cgColor : nil
      b.onClick = { [weak self] in self?.select(p) }
      v.addSubview(b)
      x += b.frame.width + 2
    }
    v.frame = NSRect(x: 0, y: 0, width: x, height: 22)
    return v
  }

  // MARK: Account

  private func accountCard() -> Card {
    let c = Card(width: Self.half, height: 96)
    let mark = ClaudeMark(size: 14, color: Style.accent)
    var title = "Claude"
    if let e = account.email { title += " · " + e }
    var right = c.bounds.width - 14
    let dot = Shapes(frame: NSRect(x: right - 6, y: 16, width: 6, height: 6))
    dot.rect(dot.bounds, color: summary?.block != nil ? Style.accent : Style.track, radius: 3)
    c.addSubview(dot)
    right -= 14
    if let plan = account.plan {
      let badge = Style.badge(plan)
      badge.frame.origin = NSPoint(x: right - badge.frame.width, y: 19 - badge.frame.height / 2)
      c.addSubview(badge)
      right = badge.frame.minX - 8
    }
    c.header(icon: mark, title: title, titleWidth: right - 32)

    let w = c.bounds.width
    var y: CGFloat = 41 // centre of the next row
    var updates: [() -> Void] = []

    /// A row: bold or plain name, an optional reset countdown, a value on the right.
    func row(_ name: String, bold: Bool, resets: (() -> Date?)?, value: String) {
      let n = label(name, size: bold ? 11.5 : 11, weight: bold ? .semibold : .medium,
                    color: bold ? Style.white : Style.grey4)
      n.frame.origin = NSPoint(x: 14, y: y - n.frame.height / 2)
      c.addSubview(n)
      let v = label(value, size: bold ? 12.5 : 11, weight: .semibold, color: Style.white, digits: true)
      v.frame.origin = NSPoint(x: w - 14 - v.frame.width, y: y - v.frame.height / 2)
      c.addSubview(v)
      if let resets {
        let icon = Style.symbol("arrow.clockwise", size: 8.5, color: Style.grey)
        icon.frame.origin = NSPoint(x: n.frame.maxX + 8, y: y - icon.frame.height / 2)
        c.addSubview(icon)
        let r = label("", size: 11, weight: .medium, color: Style.grey)
        c.addSubview(r)
        let rowY = y
        updates.append {
          guard let d = resets(), d > Date() else { r.stringValue = ""; return }
          r.stringValue = Format.remaining(d.timeIntervalSinceNow)
          r.sizeToFit()
          r.frame.origin = NSPoint(x: icon.frame.maxX + 4, y: rowY - r.frame.height / 2)
        }
      }
    }
    func bar(_ fraction: Double, _ color: NSColor, height h: CGFloat, gap: CGFloat) -> Shapes {
      let b = Shapes(frame: NSRect(x: 14, y: y + gap, width: w - 28, height: h))
      c.addSubview(b)
      b.rect(b.bounds, color: Style.track, radius: h / 2)
      if fraction > 0 {
        b.rect(NSRect(x: 0, y: 0, width: max(h, b.bounds.width * min(1, fraction)), height: h), color: color, radius: h / 2)
      }
      return b
    }
    func color(_ severity: Int) -> NSColor { [Style.accentBar, Style.orange, Style.red][min(2, max(0, severity))] }
    func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    let reading = limits.reading
    if let wk = reading?.weekly {
      row("Weekly", bold: true, resets: { wk.resets }, value: percent(wk.percent))
      _ = bar(wk.percent / 100, color(wk.severity), height: 6, gap: 9)
      y += 30
    }
    for m in reading?.models ?? [] {
      row(m.label, bold: false, resets: nil, value: percent(m.percent))
      _ = bar(m.percent / 100, color(m.severity), height: 3, gap: 8)
      y += 22
    }

    // The five-hour session: the plan's own percent when it has one, else the block's clock.
    let block = summary?.block
    let fiveHour = reading?.session
    let cost = block.map { Format.money($0.cost) } ?? "–"
    row("Session", bold: reading == nil, resets: { fiveHour?.resets ?? block?.end },
        value: fiveHour.map { percent($0.percent) + " · " + cost } ?? cost)
    let sessionBar = Shapes(frame: NSRect(x: 14, y: y + 9, width: w - 28, height: reading == nil ? 8 : 6))
    c.addSubview(sessionBar)
    updates.append {
      let h = sessionBar.bounds.height
      sessionBar.clear()
      sessionBar.rect(sessionBar.bounds, color: Style.track, radius: h / 2)
      let fraction: Double
      var tint = Style.accentDim
      if let f = fiveHour {
        fraction = f.percent / 100
        tint = color(f.severity)
      } else if let b = block, b.end > Date() {
        fraction = min(1, max(0, Date().timeIntervalSince(b.start) / b.end.timeIntervalSince(b.start)))
      } else { fraction = 0 }
      if fraction > 0 {
        sessionBar.rect(NSRect(x: 0, y: 0, width: max(h, sessionBar.bounds.width * min(1, fraction)), height: h),
                        color: tint, radius: h / 2)
      }
    }
    y = sessionBar.frame.maxY + 12

    // Footnote: extra usage, how fresh the reading is, or why there is none.
    let note = label("", size: 10, weight: .medium, color: Style.dim)
    note.frame = NSRect(x: 14, y: y - 7, width: w - 28, height: 14)
    c.addSubview(note)
    let limits = self.limits
    updates.append {
      var parts: [String] = []
      if let r = reading, let minor = r.extraMinor, let code = r.currency {
        parts.append("Extra usage " + Format.currency(Double(minor) / pow(10, Double(r.exponent)), code: code))
      }
      if limits.failed {
        parts.append("Limits unavailable")
      } else if let r = reading, limits.loading || Date().timeIntervalSince(r.at) > 120 {
        parts.append("updated " + Format.ago(r.at))
      } else if reading == nil {
        parts.append(limits.loading ? "Checking plan limits…" : "Limits unavailable")
      }
      if parts.isEmpty, let b = block, b.end > Date() {
        parts.append("5-hour block · " + Format.clock(b.start) + "–" + Format.clock(b.end))
      }
      note.stringValue = parts.joined(separator: " · ")
    }
    c.frame.size.height = y + 16

    let update = { updates.forEach { $0() } }
    update()
    tickers.append(update)
    return c
  }

  // MARK: Spending

  private func spendingCard(_ s: Usage.Summary, height: CGFloat) -> Card {
    let c = Card(width: Self.half, height: height)
    // Laid out for 96 points; a taller row (the account card's limits) spreads it out.
    let dy = (height - 96) / 2
    c.header(icon: Style.symbol("dollarsign.circle", size: 11, color: Style.grey), title: "Spending")
    let big = label(Format.money(s.totals.cost), size: 22, weight: .semibold, color: Style.white)
    big.frame.origin = NSPoint(x: 14, y: 45 + dy - big.frame.height / 2)
    c.addSubview(big)
    let api = label("API value", size: 11, weight: .medium, color: Style.grey)
    api.frame.origin = NSPoint(x: big.frame.maxX + 8, y: big.frame.maxY - api.frame.height - 3)
    c.addSubview(api)

    // One bar, split by model.
    let bar = Shapes(frame: NSRect(x: 14, y: 63 + dy, width: c.bounds.width - 28, height: 3.5))
    if s.modelShares.isEmpty { bar.rect(bar.bounds, color: Style.track, radius: 2) }
    var x: CGFloat = 0
    for (i, share) in s.modelShares.prefix(4).enumerated() {
      let w = i == min(3, s.modelShares.count - 1) ? bar.bounds.width - x : (bar.bounds.width * share).rounded()
      guard w >= 1 else { continue }
      let alpha: CGFloat = [1, 0.6, 0.38, 0.22][i]
      bar.rect(NSRect(x: x, y: 0, width: max(1, w - 2), height: 3.5), color: Style.accentBar.withAlphaComponent(alpha), radius: 1.75)
      x += w
    }
    c.addSubview(bar)

    let share = s.totals.tokens > 0 ? Double(s.totals.cacheRead) / Double(s.totals.tokens) : 0
    let line = label(Format.tokens(s.totals.tokens) + " tokens · \(Int((share * 100).rounded()))% from cache",
                     size: 10.5, weight: .medium, color: Style.grey)
    line.frame.origin = NSPoint(x: 14, y: 78 + dy - line.frame.height / 2)
    c.addSubview(line)
    return c
  }

  private func progressCard(height: CGFloat) -> Card {
    let c = Card(width: Self.half, height: height)
    c.header(icon: Style.symbol("dollarsign.circle", size: 11, color: Style.grey), title: "Spending")
    let p = usage.progress ?? 0
    let l = label("Reading history…", size: 11, weight: .medium, color: Style.grey)
    l.frame.origin = NSPoint(x: 14, y: 40)
    c.addSubview(l)
    let bar = Shapes(frame: NSRect(x: 14, y: 67, width: c.bounds.width - 28, height: 4))
    bar.rect(bar.bounds, color: Style.track, radius: 2)
    bar.rect(NSRect(x: 0, y: 0, width: max(4, bar.bounds.width * p), height: 4), color: Style.accentBar, radius: 2)
    c.addSubview(bar)
    return c
  }

  // MARK: Now

  private func nowCard() -> Card {
    let sessions = agents.sorted
    let rowH: CGFloat = 26
    let c = Card(width: Self.full, height: max(96, 28 + CGFloat(max(1, sessions.count)) * rowH + 14))
    c.header(icon: Style.symbol("waveform.path.ecg", size: 11, color: Style.accent), title: "Now")
    if sessions.contains(where: { $0.state != .done }) {
      let dot = Shapes(frame: NSRect(x: c.bounds.width - 20, y: 16, width: 6, height: 6))
      dot.rect(dot.bounds, color: Style.accent, radius: 3)
      c.addSubview(dot)
    }
    guard !sessions.isEmpty else {
      let l = label("No live sessions", size: 11.5, weight: .medium, color: Style.dim)
      l.frame.origin = NSPoint(x: 14, y: 41 - l.frame.height / 2)
      c.addSubview(l)
      return c
    }
    var y: CGFloat = 28
    for s in sessions {
      let row = Pressable(frame: NSRect(x: 6, y: y, width: c.bounds.width - 12, height: rowH))
      row.highlight = true
      row.onClick = { [weak self] in
        self?.agents.jump(to: s)
        self?.close()
      }
      let color = s.state == .attention ? Style.orange : s.state == .working ? Style.accent : Style.dim
      let mark = ClaudeMark(size: 12, color: color)
      mark.frame.origin = NSPoint(x: 8, y: (rowH - 13) / 2)
      if s.state != .done { mark.pulse(fast: s.state == .attention) }
      row.addSubview(mark)

      let time = label("", size: 11.5, weight: .semibold, color: color, digits: true)
      row.addSubview(time)
      let title = label(s.title, size: 11.5, weight: .semibold, color: s.state == .done ? Style.grey : Style.white)
      row.addSubview(title)
      let tool = s.tool
      let update = {
        let t = Format.elapsed(Date().timeIntervalSince(s.since))
        switch s.state {
        case .working: time.stringValue = (tool.map { $0 + "  " } ?? "") + t
        case .attention: time.stringValue = "needs you  " + t
        case .done:
          // Finished a moment ago, or just open and waiting for you.
          time.stringValue = Date().timeIntervalSince(s.since) < 120 ? "done" : "idle"
        }
        time.sizeToFit()
        time.frame.origin = NSPoint(x: row.bounds.width - 8 - time.frame.width, y: (rowH - time.frame.height) / 2)
        title.frame = NSRect(x: 30, y: (rowH - title.frame.height) / 2,
                             width: max(40, time.frame.minX - 40), height: title.frame.height)
      }
      update()
      tickers.append(update)
      c.addSubview(row)
      y += rowH
    }
    return c
  }

  // MARK: Trend

  private func trendCard(_ s: Usage.Summary) -> Card {
    let c = Card(width: Self.full, height: 118)
    c.header(icon: Style.symbol("chart.bar.xaxis", size: 10.5, color: Style.grey), title: "Trend")
    let name = s.period == .today ? "Today" : s.period == .week ? "7 days" : "30 days"
    let total = label(name + " · " + Format.money(s.totals.cost), size: 10.5, weight: .semibold, color: Style.grey)
    total.frame.origin = NSPoint(x: c.bounds.width - 14 - total.frame.width, y: 19 - total.frame.height / 2)
    c.addSubview(total)

    let chart = Shapes(frame: NSRect(x: 14, y: 34, width: c.bounds.width - 28, height: 58))
    let maxV = s.trend.max() ?? 0
    let n = CGFloat(max(1, s.trend.count))
    let pitch = chart.bounds.width / n
    let barW = min(30, (pitch * (s.trend.count > 24 ? 0.7 : 0.8)).rounded())
    for (i, v) in s.trend.enumerated() {
      let x = (CGFloat(i) * pitch + (pitch - barW) / 2).rounded()
      if v <= 0.005 || maxV <= 0 {
        chart.rect(NSRect(x: x, y: chart.bounds.height - 2, width: barW, height: 2), color: Style.track, radius: 1)
      } else {
        let h = max(3, (CGFloat(v / maxV) * chart.bounds.height).rounded())
        chart.rect(NSRect(x: x, y: chart.bounds.height - h, width: barW, height: h), color: Style.accentBar,
                   radius: min(4, barW / 3))
      }
    }
    c.addSubview(chart)

    let labels = s.trendLabels
    for (i, text) in labels.enumerated() where !text.isEmpty {
      let l = label(text, size: 9, weight: .semibold, color: Style.dim, digits: true)
      let x: CGFloat
      switch i {
      case 0: x = 14
      case labels.count - 1: x = c.bounds.width - 14 - l.frame.width
      default: x = 14 + chart.bounds.width * 0.5 + pitch * 0.5 - l.frame.width / 2
      }
      l.frame.origin = NSPoint(x: x, y: 104 - l.frame.height / 2)
      c.addSubview(l)
    }
    return c
  }

  // MARK: Models / Projects

  private func rankCard(symbol: String, title: String, rows: [(name: String, cost: Double)], color: NSColor) -> Card {
    let c = Card(width: Self.half, height: 94)
    c.header(icon: Style.symbol(symbol, size: 10.5, color: Style.grey), title: title)
    guard let top = rows.first?.cost, top > 0 else {
      let l = label("No usage yet", size: 11, weight: .medium, color: Style.dim)
      l.frame.origin = NSPoint(x: 14, y: 40 - l.frame.height / 2)
      c.addSubview(l)
      return c
    }
    let costW: CGFloat = 48, barMax: CGFloat = 36
    let barX = c.bounds.width - 14 - costW - barMax
    for (i, r) in rows.enumerated() {
      let mid = 38 + CGFloat(i) * 19
      let name = label(r.name, size: 11, weight: .semibold, color: Style.white)
      name.frame = NSRect(x: 14, y: mid - name.frame.height / 2, width: min(name.frame.width, barX - 22),
                          height: name.frame.height)
      c.addSubview(name)
      let bar = Shapes(frame: NSRect(x: barX, y: mid - 2, width: barMax, height: 4))
      bar.rect(NSRect(x: 0, y: 0, width: max(4, (barMax * CGFloat(r.cost / top)).rounded()), height: 4),
               color: color, radius: 2)
      c.addSubview(bar)
      let cost = label(Format.money(r.cost), size: 11, weight: .semibold, color: Style.grey)
      cost.frame.origin = NSPoint(x: c.bounds.width - 14 - cost.frame.width, y: mid - cost.frame.height / 2)
      c.addSubview(cost)
    }
    return c
  }

  // MARK: Activity

  private func activityCard(_ s: Usage.Summary) -> Card {
    let c = Card(width: Self.full, height: 118)
    c.header(icon: Style.symbol("circle.grid.3x3.fill", size: 10, color: Style.grey), title: "Activity")
    if s.streak > 0 {
      let n = label("\(s.streak)", size: 11, weight: .semibold, color: Style.orange)
      n.frame.origin = NSPoint(x: c.bounds.width - 14 - n.frame.width, y: 19 - n.frame.height / 2)
      c.addSubview(n)
      let flame = Style.symbol("flame.fill", size: 9.5, color: Style.orange)
      flame.frame.origin = NSPoint(x: n.frame.minX - 3 - flame.frame.width, y: 19 - flame.frame.height / 2)
      c.addSubview(flame)
    }

    let cell: CGFloat = 9.5, pitch: CGFloat = 11.5
    let grid = Shapes(frame: NSRect(x: 14, y: 32, width: 13 * pitch, height: 7 * pitch))
    let maxV = s.days.max() ?? 0
    let levels = [Style.track, Style.grey1, Style.dim, Style.grey, Style.grey4, Style.grey5]
    for (i, v) in s.days.enumerated() {
      let col = CGFloat(i / 7), row = CGFloat(i % 7)
      var level = 0
      if v > 0.005, maxV > 0 {
        let r = v / maxV
        level = r < 0.1 ? 1 : r < 0.25 ? 2 : r < 0.5 ? 3 : r < 0.75 ? 4 : 5
      }
      let r = NSRect(x: col * pitch, y: row * pitch, width: cell, height: cell)
      let l = grid.rect(r, color: levels[level], radius: 2.5)
      if i == s.days.count - 1 { // today
        l.borderWidth = 1
        l.borderColor = Style.white.withAlphaComponent(0.55).cgColor
      }
    }
    c.addSubview(grid)

    let x = grid.frame.maxX + 16
    let total = label(Format.money(s.gridTotal), size: 20, weight: .semibold, color: Style.white)
    total.frame.origin = NSPoint(x: x, y: 42 - total.frame.height / 2)
    c.addSubview(total)
    let weeks = label("13 weeks", size: 10.5, weight: .medium, color: Style.grey)
    weeks.frame.origin = NSPoint(x: x, y: 60 - weeks.frame.height / 2)
    c.addSubview(weeks)

    var busiest = "–"
    if let b = s.busiest { busiest = Format.day(b.day) + " · " + Format.money(b.cost) }
    for (i, (k, v)) in [("Active days", "\(s.activeDays)"), ("Busiest day", busiest)].enumerated() {
      let mid = 86 + CGFloat(i) * 15.5
      let key = label(k, size: 10.5, weight: .medium, color: Style.grey)
      key.frame.origin = NSPoint(x: x, y: mid - key.frame.height / 2)
      c.addSubview(key)
      let value = label(v, size: 10.5, weight: .semibold, color: Style.white)
      value.frame.origin = NSPoint(x: c.bounds.width - 14 - value.frame.width, y: mid - value.frame.height / 2)
      c.addSubview(value)
    }
    return c
  }

  // MARK: - Offscreen render (`--render-dashboard <png>`)

  /// Draws the dashboard with live data into a PNG, for checking the layout without a screen.
  func render(to path: String, period p: Usage.Period, done: @escaping () -> Void) {
    period = p
    usage.refresh()
    limits.refreshIfStale()
    var waited = 0
    func attempt() {
      usage.summary(p) { [self] s in
        if (usage.progress != nil || limits.loading) && waited < 600 {
          waited += 1
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: attempt)
          return
        }
        summary = s
        account = Account.read(NSHomeDirectory() + "/.claude.json")
        let w = DashboardWindow()
        let root = RootView(frame: NSRect(x: 0, y: 0, width: Silhouette.envelopeWidth(Self.width), height: 400))
        w.contentView = root
        window = w
        self.root = root
        screenFrame = NSRect(x: -20000, y: 0, width: Self.width, height: 2000)
        topInset = 32
        zone = NSRect(x: screenFrame.midX - 100, y: screenFrame.maxY - 32, width: 200, height: 32)
        maxHeight = CommandLine.arguments.contains("--short") ? 500 : 2000
        build()
        w.orderFrontRegardless()
        root.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          let scale: CGFloat = 2
          let size = root.bounds.size
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                     pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
          let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
          ctx.translateBy(x: 0, y: size.height * scale)
          ctx.scaleBy(x: scale, y: -scale) // the root layer is flipped
          root.layer?.render(in: ctx)
          try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
          done()
        }
      }
    }
    attempt()
  }
}

// MARK: - Account

/// Email and plan from ~/.claude.json. Only the `oauthAccount` object is looked at; the
/// file holds no credentials (those are in the keychain, which we don't touch).
struct Account {
  var email: String?
  var plan: String?

  static func read(_ path: String) -> Account {
    // Data read from a file starts at index 0, so offsets index it directly.
    guard let data = FileManager.default.contents(atPath: path) else { return Account() }
    guard let start = data.range(of: Data(#""oauthAccount""#.utf8))?.lowerBound else { return Account() }
    // The object is small; look only at the next few KB.
    let end = min(data.count, start + 8192)
    func value(_ key: String) -> String? {
      guard let k = data.range(of: Data("\"\(key)\"".utf8), in: start..<data.count)?.lowerBound, k < end
      else { return nil }
      var i = k + key.utf8.count + 2
      while i < end, data[i] == 0x20 || data[i] == 0x3A || data[i] == 0x0A || data[i] == 0x09 { i += 1 }
      guard i < end, data[i] == 0x22 else { return nil }
      var j = i + 1
      while j < end, data[j] != 0x22 { j += data[j] == 0x5C ? 2 : 1 }
      return j < end ? String(decoding: data[i + 1..<j], as: UTF8.self) : nil
    }
    var a = Account()
    a.email = value("emailAddress")
    a.plan = value("planDisplayName")
    if a.plan?.isEmpty ?? true {
      switch value("organizationType") {
      case "claude_max": a.plan = "Max"
      case "claude_pro": a.plan = "Pro"
      case "claude_team": a.plan = "Team"
      case "claude_enterprise": a.plan = "Enterprise"
      default: a.plan = nil
      }
    }
    return a
  }
}

// MARK: - Window and views

private final class DashboardWindow: NSPanel {
  init() {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    // Account and project names stay out of screen shares unless the user opts in.
    sharingType = UserDefaults.standard.bool(forKey: "allowScreenCapture") ? .readOnly : .none
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
  }

  override var canBecomeKey: Bool { false }
}

/// The window's content: a black fill clipped to the island silhouette, and the cards in
/// `content`, centred in the room the spring's swing needs.
private final class RootView: NSView {
  var onEnter: (() -> Void)?
  var onExit: (() -> Void)?
  let content = FlippedView()
  private let mask = CAShapeLayer()
  private var target = NSSize.zero

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    trackHover()
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.mask = mask
    content.wantsLayer = true
    addSubview(content)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// The open silhouette: `bodyWidth` of cards plus a shoulder each side, `height` tall.
  func layoutContent(bodyWidth: CGFloat, height: CGFloat) {
    target = NSSize(width: bodyWidth + 2 * Silhouette.shoulder(height), height: height)
    content.frame = NSRect(x: (bounds.width - bodyWidth) / 2, y: 0, width: bodyWidth, height: height)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mask.frame = layer?.bounds ?? bounds
    mask.path = path(target) // a running opening keeps playing over it
    CATransaction.commit()
  }

  private func path(_ size: NSSize) -> CGPath {
    Silhouette.path(size, centreX: bounds.width / 2, flipped: layer?.isGeometryFlipped ?? true, height: bounds.height)
  }

  /// Opening: the silhouette springs out of `start` (the notch or pill) to its full size and
  /// the cards fade in just behind it, growing from 94% at the top edge. Closing: the cards
  /// fade quickly and the silhouette settles back into `start` without a swing.
  func grow(from start: NSSize, opening: Bool, done: (() -> Void)?) {
    let from = opening ? start : target, to = opening ? target : start
    let (sizes, duration) = Silhouette.frames(from: from, to: to, bouncy: opening)
    let shape = CAKeyframeAnimation(keyPath: "path")
    shape.values = sizes.map(path)
    shape.duration = duration
    shape.calculationMode = .linear

    CATransaction.begin()
    CATransaction.setCompletionBlock(done)
    mask.frame = layer?.bounds ?? bounds
    mask.path = path(to)
    mask.add(shape, forKey: "grow")
    let fade = CAKeyframeAnimation(keyPath: "opacity")
    if opening {
      // The shape gets a head start; the cards arrive over its last stretch.
      fade.values = [0, 0, 1]
      fade.keyTimes = [0, 0.3, 1]
      fade.duration = 0.42
      fade.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeOut)]
      let grow = CABasicAnimation(keyPath: "transform")
      grow.fromValue = NSValue(caTransform3D: scaleFromTop(0.94))
      grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
      grow.duration = 0.42
      grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1, 0.35, 1)
      content.layer?.add(grow, forKey: "grow")
    } else {
      fade.values = [1, 0]
      fade.keyTimes = [0, 1]
      fade.duration = 0.14
      fade.timingFunctions = [CAMediaTimingFunction(name: .easeIn)]
      fade.fillMode = .forwards
      fade.isRemovedOnCompletion = false
    }
    content.layer?.add(fade, forKey: "fade")
    CATransaction.commit()
  }

  /// A scale of the cards about their top centre. Layers of views pivot on their anchor
  /// point, which AppKit puts at a corner, so the transform moves the pivot back.
  private func scaleFromTop(_ s: CGFloat) -> CATransform3D {
    guard let l = content.layer else { return CATransform3DIdentity }
    let w = l.bounds.width, h = l.bounds.height
    let top: CGFloat = (l.superlayer?.isGeometryFlipped ?? true) ? 0 : h
    let tx = (w / 2 - l.anchorPoint.x * w) * (1 - s)
    let ty = (top - l.anchorPoint.y * h) * (1 - s)
    return CATransform3DConcat(CATransform3DMakeScale(s, s, 1), CATransform3DMakeTranslation(tx, ty, 0))
  }

  override func mouseEntered(with event: NSEvent) { onEnter?() }
  override func mouseExited(with event: NSEvent) { onExit?() }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The island's outline and its motion. The top corners curve outwards into the screen edge
/// (the shoulders) and the bottom corners are rounded; both grow with the height, so a
/// notch-sized shape has the notch's small corners and the open panel its large ones.
enum Silhouette {
  /// How far a side may swing past its target; the window keeps this much room.
  static let overshoot: CGFloat = 12

  static func shoulder(_ height: CGFloat) -> CGFloat { min(14, height * 0.2) }
  static func radius(_ height: CGFloat) -> CGFloat { min(26, height * 0.33) }
  static func envelopeWidth(_ body: CGFloat) -> CGFloat { body + 2 * 14 + 2 * overshoot }

  /// The outline for `size` (shoulders included), hanging from the top edge, centred on
  /// `centreX`. `flipped` says whether y grows downwards in the layer it's drawn in.
  static func path(_ size: NSSize, centreX: CGFloat, flipped: Bool, height: CGFloat) -> CGPath {
    let w = max(size.width, 0), h = max(size.height, 0)
    let x0 = centreX - w / 2
    let sh = min(shoulder(h), w / 4)
    let r = min(radius(h), h / 2, max(0, (w - 2 * sh) / 2))
    // Built with y growing downwards, then flipped if the layer isn't.
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x0, y: 0))
    p.addLine(to: CGPoint(x: x0 + w, y: 0))
    p.addQuadCurve(to: CGPoint(x: x0 + w - sh, y: sh), control: CGPoint(x: x0 + w - sh, y: 0))
    p.addLine(to: CGPoint(x: x0 + w - sh, y: h - r))
    p.addQuadCurve(to: CGPoint(x: x0 + w - sh - r, y: h), control: CGPoint(x: x0 + w - sh, y: h))
    p.addLine(to: CGPoint(x: x0 + sh + r, y: h))
    p.addQuadCurve(to: CGPoint(x: x0 + sh, y: h - r), control: CGPoint(x: x0 + sh, y: h))
    p.addLine(to: CGPoint(x: x0 + sh, y: sh))
    p.addQuadCurve(to: CGPoint(x: x0, y: 0), control: CGPoint(x: x0 + sh, y: 0))
    p.closeSubpath()
    if flipped { return p }
    var t = CGAffineTransform(translationX: 0, y: height).scaledBy(x: 1, y: -1)
    return p.copy(using: &t) ?? p
  }

  /// A damped spring's progress from 0 to 1 at time `t`, for a perceived `duration` and a
  /// `bounce` between 0 (critically damped) and 1.
  static func spring(_ t: Double, duration: Double, bounce: Double) -> Double {
    let omega = 2 * Double.pi / duration
    let zeta = 1 - bounce
    if zeta >= 1 { return 1 - exp(-omega * t) * (1 + omega * t) }
    let wd = omega * (1 - zeta * zeta).squareRoot()
    return 1 - exp(-zeta * omega * t) * (cos(wd * t) + zeta * omega / wd * sin(wd * t))
  }

  /// The sizes to show at 60 frames a second from `from` to `to`. Width and height move on
  /// their own springs, the height a little quicker, so the shape drops and then widens.
  /// Opening swings past the target by at most `overshoot`; closing doesn't swing.
  static func frames(from: NSSize, to: NSSize, bouncy: Bool) -> ([NSSize], CFTimeInterval) {
    let width = bouncy ? (0.42, 0.2) : (0.28, 0.0)
    let height = bouncy ? (0.36, 0.16) : (0.24, 0.0)
    func side(_ a: CGFloat, _ b: CGFloat, _ spring: (Double, Double), _ t: Double) -> CGFloat {
      let v = a + (b - a) * CGFloat(self.spring(t, duration: spring.0, bounce: spring.1))
      return b >= a ? min(v, b + overshoot) : max(v, b - overshoot)
    }
    var sizes: [NSSize] = []
    var t = 0.0
    while true {
      let s = NSSize(width: side(from.width, to.width, width, t), height: side(from.height, to.height, height, t))
      sizes.append(s)
      let settled = abs(s.width - to.width) < 0.5 && abs(s.height - to.height) < 0.5
      if (settled && t >= max(width.0, height.0) * 0.6) || t > 1.2 { break }
      t += 1.0 / 60
    }
    sizes[sizes.count - 1] = to
    return (sizes, Double(sizes.count - 1) / 60)
  }
}

/// The cards' scroll view: an overlay scroller, and the cards fading out over 14 points at
/// an edge with more beyond it, so none is cut by a hard line.
private final class FadingScrollView: NSScrollView {
  private let fade = CAGradientLayer()

  override init(frame: NSRect) {
    super.init(frame: frame)
    drawsBackground = false
    contentView.drawsBackground = false
    borderType = .noBorder
    hasVerticalScroller = true
    autohidesScrollers = true
    scrollerStyle = .overlay
    scrollerKnobStyle = .light
    verticalScrollElasticity = .allowed
    wantsLayer = true
    contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                           object: contentView)
    layer?.mask = fade
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { NotificationCenter.default.removeObserver(self) }

  @objc private func scrolled() { updateFade() }

  func updateFade() {
    let h = max(bounds.height, 1)
    let offset = contentView.bounds.origin.y
    let total = documentView?.frame.height ?? 0
    let edge = 14 / h
    let top = offset > 1, bottom = offset + h < total - 1
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fade.frame = layer?.bounds ?? bounds
    // Gradient points run bottom to top unless the layer is flipped.
    let flipped = layer?.isGeometryFlipped ?? false
    fade.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
    fade.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
    let clear = CGColor(gray: 0, alpha: 0), solid = CGColor(gray: 0, alpha: 1)
    fade.colors = [top ? clear : solid, solid, solid, bottom ? clear : solid]
    fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
    CATransaction.commit()
  }
}

private class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// A rounded card with a symbol + title header.
private final class Card: FlippedView {
  init(width: CGFloat, height: CGFloat) {
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    wantsLayer = true
    layer?.backgroundColor = Style.card.cgColor
    layer?.cornerRadius = 18
    layer?.cornerCurve = .continuous
  }

  required init?(coder: NSCoder) { fatalError() }

  func header(icon: NSView, title: String, titleWidth: CGFloat? = nil) {
    icon.frame.origin = NSPoint(x: 14 + (12 - icon.frame.width) / 2, y: 19 - icon.frame.height / 2)
    addSubview(icon)
    let l = label(title, size: 11.5, weight: .semibold, color: Style.white)
    l.frame = NSRect(x: 32, y: 19 - l.frame.height / 2, width: min(l.frame.width, titleWidth ?? .greatestFiniteMagnitude),
                     height: l.frame.height)
    addSubview(l)
  }
}

/// Rectangles as sublayers: background colour only, no backing store. `rect` takes
/// top-left based coordinates like the rest of the dashboard.
private final class Shapes: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  @discardableResult
  func rect(_ r: NSRect, color: NSColor, radius: CGFloat) -> CALayer {
    let l = CALayer()
    l.frame = CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    l.backgroundColor = color.cgColor
    l.cornerRadius = radius
    layer?.addSublayer(l)
    return l
  }

  func clear() { layer?.sublayers?.forEach { $0.removeFromSuperlayer() } }
}

/// Click target with an optional hover highlight.
private final class Pressable: FlippedView {
  var onClick: (() -> Void)?
  var highlight = false {
    didSet {
      wantsLayer = true
      layer?.cornerRadius = 8
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    guard highlight else { return }
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Style.white.withAlphaComponent(0.06).cgColor }
  override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
  override func mouseDown(with event: NSEvent) { onClick?() }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Claude's starburst, drawn as one shape layer.
private final class ClaudeMark: NSView {
  private let shape = CAShapeLayer()

  init(size: CGFloat, color: NSColor) {
    super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    wantsLayer = true
    shape.frame = bounds
    shape.fillColor = color.cgColor
    shape.path = Self.path(size)
    layer?.addSublayer(shape)
  }

  required init?(coder: NSCoder) { fatalError() }

  func pulse(fast: Bool) {
    let a = CABasicAnimation(keyPath: "opacity")
    a.fromValue = 1
    a.toValue = 0.35
    a.duration = fast ? 0.5 : 0.9
    a.autoreverses = true
    a.repeatCount = .infinity
    shape.add(a, forKey: "pulse")
  }

  private static func path(_ size: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let c = CGPoint(x: size / 2, y: size / 2)
    let rays = 11
    for i in 0..<rays {
      let angle = CGFloat(i) / CGFloat(rays) * 2 * .pi + 0.2
      let length = size / 2 * (i % 2 == 0 ? 1 : 0.8)
      let base = size * 0.07, tip = size * 0.035
      let dir = CGPoint(x: cos(angle), y: sin(angle)), perp = CGPoint(x: -dir.y, y: dir.x)
      let inner = size * 0.08
      p.move(to: CGPoint(x: c.x + dir.x * inner + perp.x * base, y: c.y + dir.y * inner + perp.y * base))
      p.addLine(to: CGPoint(x: c.x + dir.x * length + perp.x * tip, y: c.y + dir.y * length + perp.y * tip))
      p.addLine(to: CGPoint(x: c.x + dir.x * length - perp.x * tip, y: c.y + dir.y * length - perp.y * tip))
      p.addLine(to: CGPoint(x: c.x + dir.x * inner - perp.x * base, y: c.y + dir.y * inner - perp.y * base))
      p.closeSubpath()
    }
    p.addEllipse(in: CGRect(x: c.x - size * 0.12, y: c.y - size * 0.12, width: size * 0.24, height: size * 0.24))
    return p
  }
}

// MARK: - Style

private enum Style {
  static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }

  static let card = rgb(0x151515)
  static let chip = rgb(0x262626)
  static let track = rgb(0x2A2A2A)
  static let white = rgb(0xF2F2F2)
  static let grey = rgb(0x8E8E8E)
  static let dim = rgb(0x666666)
  static let accent = rgb(0xD98B6E) // Claude clay
  static let accentBar = rgb(0xC8846A)
  static let accentDim = rgb(0x6E4A3C)
  static let orange = rgb(0xF4A759)
  static let red = rgb(0xE5534B)
  static let grey1 = rgb(0x494949)
  static let grey4 = rgb(0xBABABA)
  static let grey5 = rgb(0xEBEBEB)

  static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
    let image = NSImage.symbol(name, size, .semibold)
    let v = NSImageView(image: image)
    v.imageScaling = .scaleNone
    v.contentTintColor = color
    v.frame.size = image.size
    return v
  }

  static func badge(_ text: String) -> NSView {
    let l = label(text, size: 10, weight: .semibold, color: accent)
    let v = FlippedView(frame: NSRect(x: 0, y: 0, width: l.frame.width + 14, height: 17))
    v.wantsLayer = true
    v.layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
    v.layer?.cornerRadius = 8.5
    l.frame.origin = NSPoint(x: 7, y: (17 - l.frame.height) / 2)
    v.addSubview(l)
    return v
  }
}

// MARK: - Formatting

enum Format {
  private static let number: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = .current
    return f
  }()

  private static func fixed(_ v: Double, _ digits: Int) -> String {
    number.minimumFractionDigits = digits
    number.maximumFractionDigits = digits
    return number.string(from: NSNumber(value: v)) ?? String(v)
  }

  /// "$0,01", "$26,42", "$233", "$1 634", "$10K" (separators from the user's locale).
  static func money(_ v: Double) -> String {
    if v >= 10_000 { return "$" + fixed(v / 1000, 0) + "K" }
    return "$" + fixed(v, v >= 100 ? 0 : 2)
  }

  static func tokens(_ n: Int64) -> String {
    let v = Double(n)
    if v >= 1e9 { return fixed(v / 1e9, v >= 1e10 ? 0 : 1) + "B" }
    if v >= 1e6 { return fixed(v / 1e6, v >= 1e7 ? 0 : 1) + "M" }
    if v >= 1e3 { return fixed(v / 1e3, 0) + "K" }
    return fixed(v, 0)
  }

  /// "0:23", "12:05", "1:02:09".
  static func elapsed(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
  }

  /// "4h 51m", "51m".
  static func remaining(_ t: TimeInterval) -> String {
    let m = max(0, Int(t / 60))
    if m >= 24 * 60 { return "\(m / 1440)d \(m % 1440 / 60)h" }
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
  }

  /// "3m ago", "2h ago", "just now".
  static func ago(_ d: Date) -> String {
    let m = Int(Date().timeIntervalSince(d) / 60)
    return m < 1 ? "just now" : m < 60 ? "\(m)m ago" : m < 1440 ? "\(m / 60)h ago" : "\(m / 1440)d ago"
  }

  private static let currencyFormat: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.locale = .current
    return f
  }()

  /// An amount in `code` (ISO 4217), in the user's locale: "€557,53".
  static func currency(_ v: Double, code: String) -> String {
    currencyFormat.currencyCode = code
    return currencyFormat.string(from: NSNumber(value: v)) ?? String(format: "%.2f %@", v, code)
  }

  private static let clockFormat: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f
  }()

  static func clock(_ d: Date) -> String { clockFormat.string(from: d) }

  private static let dayFormat: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("d MMM")
    return f
  }()

  static func day(_ d: Date) -> String { dayFormat.string(from: d) }

  private static let weekdayFormat: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEE")
    return f
  }()

  static func weekday(_ d: Date) -> String { weekdayFormat.string(from: d) }
}
