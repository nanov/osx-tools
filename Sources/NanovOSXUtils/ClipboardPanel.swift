import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// The ⌃V clipboard history: a command-palette window with a search line, pinned and recent
/// entries, an optional preview pane and a strip of key hints. It fits its content, up to a cap,
/// and shares the notch dashboard's radii and clay accent. Built on open, released on close.
///
/// Keys: ↑/↓ or ⌃P/⌃N move; Return pastes into the app that was in front; ⇧Return only copies;
/// ⌥Return pastes as plain text; ⌘1…⌘9 paste the first nine; ⌥P pins; ⌥⌫ or ⌘⌫ deletes;
/// Space (after moving with the arrows) toggles the preview; Esc closes. Typing searches.
final class ClipboardPanel: NSObject, NSTextFieldDelegate {
  private let clipboard: Clipboard
  private let window: ClipboardWindow
  /// The window's background: Liquid Glass on macOS 26 and later, the popover material before.
  private var surface: NSView!
  /// Holds everything drawn on the surface (the glass's content view, or the material itself).
  private var effect: NSView!
  private var usesGlass = false
  private let search = SearchField()
  private let previewButton = IconButton()
  private let scroll = NSScrollView()
  private let list = FlippedClipView()
  private let footerCount = NSTextField(labelWithString: "")
  private var preview: NSView?
  private var previewHost: NSView?
  private var previewWidth: NSLayoutConstraint?
  private var rows: [ClipRow] = []
  private var shown: [Clipboard.Entry] = []
  private var selected: UUID?
  /// Space toggles the preview only once the arrows have moved the selection, so a space typed
  /// into the search stays a space.
  private var navigated = false
  private var previewOn = UserDefaults.standard.bool(forKey: "clipboardPreview")
  private var monitors: [Any] = []
  private var activation: NSObjectProtocol?
  private var thumbs: [UUID: NSImage] = [:]
  private var apps: [String: (name: String, icon: NSImage)?] = [:]
  private let target: NSRunningApplication?
  /// Where the window's top edge stays while its height follows the content.
  private var top: CGFloat = 0
  private var screenFrame = NSRect.zero
  private var shownOnce = false
  var onClose: (() -> Void)?

  static let width: CGFloat = 640
  static let previewPane: CGFloat = 300
  static let radius: CGFloat = 18 // the dashboard's card radius
  static let header: CGFloat = 54
  static let footer: CGFloat = 34

  init(clipboard: Clipboard, appearance: NSAppearance? = nil) {
    self.clipboard = clipboard
    let front = NSWorkspace.shared.frontmostApplication
    target = front?.bundleIdentifier != Bundle.main.bundleIdentifier && front?.activationPolicy == .regular ? front : nil
    window = ClipboardWindow()
    super.init()
    window.appearance = appearance
    place()
    build()
  }

  // MARK: - Open / close

  func show() {
    window.alphaValue = 0
    window.orderFrontRegardless()
    window.makeKey()
    window.makeFirstResponder(search)
    shownOnce = true
    // A short fade, and a slight growth unless Reduce Motion is on.
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.12
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      window.animator().alphaValue = 1
    }
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = surface.layer {
      let grow = CABasicAnimation(keyPath: "transform")
      let b = layer.bounds, s: CGFloat = 0.98
      grow.fromValue = NSValue(caTransform3D: CATransform3DConcat(
        CATransform3DMakeScale(s, s, 1), CATransform3DMakeTranslation(b.width * (1 - s) / 2, b.height * (1 - s) / 2, 0)))
      grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
      grow.duration = 0.12
      grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
      layer.add(grow, forKey: "open")
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) ?? e }
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    let outside = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
      guard let self, !self.window.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return }
      self.close()
    }
    monitors = [local, outside].compactMap { $0 }
    activation = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] n in
      let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      if app?.bundleIdentifier != Bundle.main.bundleIdentifier { self?.close() }
    }
  }

  func close() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
    activation = nil
    if let sheet = window.attachedSheet { window.endSheet(sheet) }
    window.makeFirstResponder(nil) // ends the field editor and its caret timer
    window.orderOut(nil)
    if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    resizeObserver = nil
    window.contentView = nil
    window.close()
    // Hand the pages the views used back to the system rather than keep them for next time.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { malloc_zone_pressure_relief(nil, 0) }
    rows = []
    thumbs = [:]
    apps = [:]
    onClose?()
    onClose = nil
  }

  /// On the screen under the pointer, centred, its top a fifth of the way down.
  private func place() {
    let mouse = NSEvent.mouseLocation
    screenFrame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
    top = screenFrame.maxY - (screenFrame.height * 0.2).rounded()
    window.setFrame(NSRect(x: screenFrame.midX - Self.width / 2, y: top - 300, width: Self.width, height: 300),
                    display: false)
  }

  private var widthNow: CGFloat { Self.width + (previewOn ? Self.previewPane : 0) }

  /// The most the list may take before it scrolls; the cut lands mid-row so the next one peeks.
  private var listCap: CGFloat {
    min(536, top - screenFrame.minY - 24 - Self.header - Self.footer)
  }

  /// Resizes the window around `listHeight`, keeping the top edge put; animated once visible.
  private func fit(listHeight: CGFloat) {
    let height = Self.header + 1 + listHeight + 1 + Self.footer
    let width = min(widthNow, screenFrame.width - 32)
    let frame = NSRect(x: screenFrame.midX - width / 2, y: top - height, width: width, height: height)
    guard frame != window.frame else { return }
    if shownOnce && window.isVisible {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.15
        ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
        window.animator().setFrame(frame, display: true)
      }
    } else {
      window.setFrame(frame, display: true)
    }
    window.invalidateShadow()
  }

  // MARK: - Layout

  private func build() {
    if #available(macOS 26, *), !UserDefaults.standard.bool(forKey: "clipboardNoGlass") {
      // The system glass: it draws the rounded shape, the edge and the shadow, and adapts the
      // text and symbols placed in its content view to whatever is behind it.
      let glass = NSGlassEffectView()
      glass.style = .regular
      glass.cornerRadius = Self.radius
      let content = NSView()
      glass.contentView = content
      surface = glass
      effect = content
      usesGlass = true
    } else {
      let material = NSVisualEffectView()
      material.material = .popover
      material.blendingMode = .behindWindow
      material.state = .active
      material.maskImage = Self.roundedMask(Self.radius)
      surface = material
      effect = material
    }
    surface.wantsLayer = true
    window.contentView = surface
    let outline = OutlineView()
    outline.translatesAutoresizingMaskIntoConstraints = false

    let lens = NSImageView(image: symbol("magnifyingglass", 15, .medium))
    lens.contentTintColor = .tertiaryLabelColor
    search.delegate = self
    search.placeholderAttributedString = NSAttributedString(string: "Search clipboard", attributes: [
      .font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.tertiaryLabelColor,
    ])

    previewButton.configure(symbol: "sidebar.right", tip: "Preview (Space)", target: self, action: #selector(togglePreview))
    let closeButton = IconButton()
    closeButton.configure(symbol: "xmark", tip: "Close (Esc)", target: self, action: #selector(closeClicked), size: 11)

    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.verticalScrollElasticity = .none
    scroll.automaticallyAdjustsContentInsets = false
    scroll.documentView = list

    let hints = NSTextField(labelWithAttributedString: Self.hints())
    footerCount.font = .systemFont(ofSize: 11)
    footerCount.textColor = .tertiaryLabelColor
    let more = IconButton()
    more.configure(symbol: "ellipsis", tip: "More", target: self, action: #selector(moreClicked), size: 12)

    let previewHost = NSView()
    self.previewHost = previewHost
    let topRule = Hairline(), bottomRule = Hairline()
    for v in [lens, search, previewButton, closeButton, topRule, scroll, previewHost, bottomRule, hints, footerCount, more,
              outline] as [NSView] where v !== outline || !usesGlass {
      v.translatesAutoresizingMaskIntoConstraints = false
      effect.addSubview(v)
    }
    let previewWidth = previewHost.widthAnchor.constraint(equalToConstant: previewOn ? Self.previewPane : 0)
    self.previewWidth = previewWidth
    let headerMid = effect.topAnchor
    if !usesGlass {
      NSLayoutConstraint.activate([
        outline.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
        outline.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        outline.topAnchor.constraint(equalTo: effect.topAnchor),
        outline.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
      ])
    }
    NSLayoutConstraint.activate([
      lens.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
      lens.centerYAnchor.constraint(equalTo: headerMid, constant: Self.header / 2),
      search.leadingAnchor.constraint(equalTo: lens.trailingAnchor, constant: 10),
      search.centerYAnchor.constraint(equalTo: lens.centerYAnchor),
      previewButton.leadingAnchor.constraint(greaterThanOrEqualTo: search.trailingAnchor, constant: 12),
      previewButton.centerYAnchor.constraint(equalTo: lens.centerYAnchor),
      closeButton.leadingAnchor.constraint(equalTo: previewButton.trailingAnchor, constant: 4),
      closeButton.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
      closeButton.centerYAnchor.constraint(equalTo: lens.centerYAnchor),
      search.trailingAnchor.constraint(equalTo: previewButton.leadingAnchor, constant: -12),

      topRule.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      topRule.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      topRule.topAnchor.constraint(equalTo: effect.topAnchor, constant: Self.header),
      topRule.heightAnchor.constraint(equalToConstant: 1),
      scroll.topAnchor.constraint(equalTo: topRule.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
      previewHost.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
      previewHost.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      previewHost.topAnchor.constraint(equalTo: topRule.bottomAnchor),
      previewHost.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
      previewWidth,
      bottomRule.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      bottomRule.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      bottomRule.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -Self.footer),
      bottomRule.heightAnchor.constraint(equalToConstant: 1),

      hints.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
      hints.centerYAnchor.constraint(equalTo: effect.bottomAnchor, constant: -Self.footer / 2),
      more.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
      more.centerYAnchor.constraint(equalTo: hints.centerYAnchor),
      footerCount.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -6),
      footerCount.centerYAnchor.constraint(equalTo: hints.centerYAnchor),
      footerCount.leadingAnchor.constraint(greaterThanOrEqualTo: hints.trailingAnchor, constant: 12),
    ])
    hints.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    hints.lineBreakMode = .byTruncatingTail
    updatePreviewButton()
    reload()
  }

  /// "↵ Paste  ⌥↵ Plain text  ⌥P Pin  esc Close": keys in grey, words a step quieter.
  private static func hints() -> NSAttributedString {
    let out = NSMutableAttributedString()
    let keyFont = NSFont.systemFont(ofSize: 11, weight: .semibold), wordFont = NSFont.systemFont(ofSize: 11)
    for (i, (key, word)) in [("↵", "Paste"), ("⌥↵", "Plain text"), ("⌥P", "Pin"), ("esc", "Close")].enumerated() {
      if i > 0 { out.append(NSAttributedString(string: "     ", attributes: [.font: wordFont])) }
      out.append(NSAttributedString(string: key, attributes: [.font: keyFont, .foregroundColor: NSColor.secondaryLabelColor]))
      out.append(NSAttributedString(string: " " + word, attributes: [.font: wordFont, .foregroundColor: NSColor.tertiaryLabelColor]))
    }
    return out
  }

  /// A stretchable rounded mask, so the material, its vibrancy and the window shadow share the
  /// rounded outline.
  static func roundedMask(_ r: CGFloat) -> NSImage {
    let side = r * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    image.resizingMode = .stretch
    return image
  }

  private func symbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
  }

  /// Rebuilds the list from the history and the search.
  func reload() {
    let tokens = search.stringValue.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    let all = clipboard.entries
    shown = tokens.isEmpty ? all : all.filter { e in
      let hay = (e.preview + " " + e.paths.joined(separator: " ")).lowercased()
      return tokens.allSatisfy { hay.contains($0) || (e.kind == .text && (clipboard.fullText(e)?.lowercased().contains($0) ?? false)) }
    }
    if selected == nil || !shown.contains(where: { $0.id == selected }) { selected = shown.first?.id }
    footerCount.stringValue = all.count == 1 ? "1 item" : "\(all.count) items"
    layoutList(grouped: tokens.isEmpty)
    updatePreview()
  }

  private var listWidth: CGFloat = 0
  private var layingOut = false
  private var resizeObserver: NSObjectProtocol?

  /// Lay the rows out again when the list's width changes (window placed, preview toggled).
  private func followWidth() {
    guard resizeObserver == nil else { return }
    scroll.contentView.postsFrameChangedNotifications = true
    resizeObserver = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak self] _ in
      guard let self, !layingOut, abs(scroll.contentSize.width - listWidth) > 0.5 else { return }
      reload()
    }
  }

  private func layoutList(grouped: Bool) {
    followWidth()
    list.subviews.forEach { $0.removeFromSuperview() }
    rows = []
    // Rows are measured against the list's final width: the window's width is known up front,
    // only its height follows the content.
    layingOut = true
    fitWidthOnly()
    window.contentView?.layoutSubtreeIfNeeded()
    layingOut = false
    let width = max(scroll.contentSize.width, 200)
    listWidth = width
    effectAppearance {
      if shown.isEmpty {
        let first = clipboard.entries.isEmpty
        let empty = EmptyState(title: first ? "Nothing copied yet" : "No matches",
                               hint: first ? "Copy something to start" : "Try a different search",
                               symbol: symbol(first ? "doc.on.clipboard" : "magnifyingglass", 26, .light))
        let h: CGFloat = previewOn ? 300 : 180
        empty.frame = NSRect(x: 0, y: 0, width: width, height: h)
        list.addSubview(empty)
        list.frame = empty.frame
        fit(listHeight: h)
        return
      }
      var y: CGFloat = 6
      let pinned = grouped ? shown.filter(\.pinned) : []
      let recent = grouped ? shown.filter { !$0.pinned } : shown
      func section(_ title: String?, _ entries: [Clipboard.Entry]) {
        guard !entries.isEmpty else { return }
        if let title {
          let h = NSTextField(labelWithString: title)
          h.font = .systemFont(ofSize: 11, weight: .semibold)
          h.textColor = .secondaryLabelColor
          h.sizeToFit()
          h.frame.origin = NSPoint(x: 20, y: y + 6)
          list.addSubview(h)
          y += 26
        }
        for e in entries {
          let index = shown.prefix(9).firstIndex { $0.id == e.id }
          let row = ClipRow(entry: e, shortcut: index, thumb: thumb(e), app: app(e.app), width: width - 16,
                            text: e.kind == .text ? Snippet(e) : nil, panel: self)
          row.frame.origin = NSPoint(x: 8, y: y)
          row.selected = e.id == selected
          list.addSubview(row)
          rows.append(row)
          y += row.frame.height + 2
        }
        y += 8 // groups sit further apart than rows
      }
      section(grouped && !pinned.isEmpty ? "Pinned" : nil, pinned)
      section(grouped && !pinned.isEmpty ? "Recent" : nil, recent)
      y -= 2
      let listHeight = min(max(y, previewOn ? 300 : 0), listCap)
      list.frame = NSRect(x: 0, y: 0, width: width, height: max(y, listHeight))
      fit(listHeight: listHeight)
    }
  }

  /// Dynamic colours resolve to the window's appearance while views are built.
  private func effectAppearance(_ body: () -> Void) {
    var done = false
    window.effectiveAppearance.performAsCurrentDrawingAppearance { body(); done = true }
    if !done { body() }
  }

  /// Sets the width for the preview state before the rows are measured.
  private func fitWidthOnly() {
    let width = min(widthNow, screenFrame.width - 32)
    guard abs(window.frame.width - width) > 0.5 else { return }
    var f = window.frame
    f.origin.x = screenFrame.midX - width / 2
    f.size.width = width
    window.setFrame(f, display: false)
  }

  private func thumb(_ e: Clipboard.Entry) -> NSImage? {
    if let t = thumbs[e.id] { return t }
    var image: NSImage?
    if e.kind == .image {
      image = NSImage(contentsOf: Clipboard.thumbs.appendingPathComponent(e.id.uuidString + ".png"))
    } else if e.kind == .files, let p = e.paths.first {
      // The real Finder icon, or the type's icon when the file is gone.
      let icon = FileManager.default.fileExists(atPath: p) ? NSWorkspace.shared.icon(forFile: p)
        : NSWorkspace.shared.icon(for: UTType(filenameExtension: (p as NSString).pathExtension) ?? .data)
      image = Self.flatten(icon, 30)
    }
    thumbs[e.id] = image
    return image
  }

  /// Draws an icon once at the size it is shown, rather than keep every representation it carries.
  private static func flatten(_ icon: NSImage, _ side: CGFloat) -> NSImage {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * scale), pixelsHigh: Int(side * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return icon }
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    let out = NSImage(size: rep.size)
    out.addRepresentation(rep)
    return out
  }

  /// The source app's name and icon, looked up once per opening.
  private func app(_ bundleID: String?) -> (name: String, icon: NSImage)? {
    guard let bundleID else { return nil }
    if let cached = apps[bundleID] { return cached }
    var found: (name: String, icon: NSImage)?
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
      found = (name, Self.flatten(NSWorkspace.shared.icon(forFile: url.path), 13))
    }
    apps[bundleID] = found
    return found
  }

  func setSampleThumb(_ id: UUID, _ image: NSImage) { thumbs[id] = image }

  // MARK: - Selection and actions

  private func select(_ id: UUID?, scroll toVisible: Bool = true) {
    selected = id
    for r in rows { r.selected = r.entry.id == id }
    if toVisible, let r = rows.first(where: { $0.entry.id == id }) {
      list.scrollToVisible(r.frame.insetBy(dx: 0, dy: -8))
    }
    updatePreview()
  }

  private func move(_ step: Int) {
    guard !shown.isEmpty else { return }
    let i = shown.firstIndex { $0.id == selected } ?? -step
    navigated = true
    select(shown[max(0, min(shown.count - 1, i + step))].id)
  }

  fileprivate func activate(_ id: UUID, plain: Bool = false, pasting: Bool = true) {
    guard clipboard.copy(id, plain: plain) else { return NSSound.beep() }
    let app = target
    close()
    guard pasting, let app, !app.isTerminated else { return }
    app.activate()
    guard AX.trusted else { return NSSound.beep() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Clipboard.postPaste() }
  }

  fileprivate func menu(for id: UUID) -> NSMenu {
    let m = NSMenu()
    let pinned = clipboard.entries.first { $0.id == id }?.pinned ?? false
    for (title, action) in [("Paste", #selector(menuPaste)), ("Paste as Plain Text", #selector(menuPastePlain)),
                            ("Copy", #selector(menuCopy)), ("-", nil), (pinned ? "Unpin" : "Pin", #selector(menuPin)),
                            ("-", nil), ("Delete", #selector(menuDelete))] as [(String, Selector?)] {
      if title == "-" { m.addItem(.separator()); continue }
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      item.representedObject = id
      m.addItem(item)
    }
    return m
  }

  @objc private func menuPaste(_ i: NSMenuItem) { (i.representedObject as? UUID).map { activate($0) } }
  @objc private func menuPastePlain(_ i: NSMenuItem) { (i.representedObject as? UUID).map { activate($0, plain: true) } }
  @objc private func menuCopy(_ i: NSMenuItem) { (i.representedObject as? UUID).map { activate($0, pasting: false) } }
  @objc private func menuPin(_ i: NSMenuItem) { (i.representedObject as? UUID).map { pin($0) } }
  @objc private func menuDelete(_ i: NSMenuItem) { (i.representedObject as? UUID).map { delete($0) } }

  fileprivate func pin(_ id: UUID) {
    clipboard.togglePin(id)
    reload()
    select(id)
  }

  fileprivate func delete(_ id: UUID) {
    let i = shown.firstIndex { $0.id == id } ?? 0
    clipboard.remove(id)
    selected = nil
    reload()
    if !shown.isEmpty { select(shown[min(i, shown.count - 1)].id) }
  }

  fileprivate func hovered(_ id: UUID) {
    guard !navigated else { return }
    selected = id
    for r in rows { r.selected = r.entry.id == id }
    updatePreview()
  }

  @objc private func closeClicked() { close() }

  @objc private func moreClicked(_ sender: NSButton) {
    let m = NSMenu()
    let clear = NSMenuItem(title: "Clear Recent…", action: #selector(clearClicked), keyEquivalent: "")
    clear.target = self
    clear.isEnabled = clipboard.entries.contains { !$0.pinned }
    m.autoenablesItems = false
    m.addItem(clear)
    m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }

  @objc private func clearClicked() {
    let alert = NSAlert()
    alert.messageText = "Clear recent clipboard history?"
    alert.informativeText = "Pinned entries are kept."
    alert.addButton(withTitle: "Clear")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] r in
      guard r == .alertFirstButtonReturn else { return }
      self?.clipboard.clearRecent()
      self?.reload()
    }
  }

  @objc private func togglePreview() { setPreview(!previewOn, remember: true) }

  fileprivate func setPreview(_ on: Bool, remember: Bool) {
    guard on != previewOn else { return }
    previewOn = on
    if remember { UserDefaults.standard.set(previewOn, forKey: "clipboardPreview") }
    previewWidth?.constant = previewOn ? Self.previewPane : 0
    updatePreviewButton()
    reload()
    select(selected)
  }

  func setSamplePreview(_ on: Bool) { setPreview(on, remember: false) }

  private func updatePreviewButton() {
    previewButton.active = previewOn
  }

  private func updatePreview() {
    preview?.removeFromSuperview()
    preview = nil
    guard previewOn, let host = previewHost else { return }
    var pane: PreviewPane!
    effectAppearance {
      pane = PreviewPane(entry: shown.first { $0.id == selected }, clipboard: clipboard,
                         thumb: shown.first { $0.id == selected }.flatMap { thumbs[$0.id] })
    }
    pane.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(pane)
    NSLayoutConstraint.activate([
      pane.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      pane.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      pane.topAnchor.constraint(equalTo: host.topAnchor),
      pane.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
    preview = pane
  }

  func controlTextDidChange(_ obj: Notification) {
    navigated = false
    selected = nil
    reload()
  }

  // MARK: - Keys

  private func key(_ e: NSEvent) -> NSEvent? {
    guard e.window === window, window.attachedSheet == nil else { return e }
    let mods = e.modifierFlags.intersection([.command, .option, .shift, .control])
    let chars = e.charactersIgnoringModifiers?.lowercased()
    let code = Int(e.keyCode)
    switch code {
    case kVK_Escape:
      close()
      return nil
    case kVK_Return, kVK_ANSI_KeypadEnter:
      guard let id = selected else { return nil }
      if mods.isEmpty { activate(id) }
      else if mods == [.shift] { activate(id, pasting: false) }
      else if mods == [.option] { activate(id, plain: true) }
      return nil
    case kVK_DownArrow:
      move(1); return nil
    case kVK_UpArrow:
      move(-1); return nil
    case kVK_Space where mods.isEmpty && navigated:
      setPreview(!previewOn, remember: true); return nil
    default: break
    }
    // Plain ⌫ stays with the search field; ⌥⌫ and ⌘⌫ delete the entry.
    if code == kVK_Delete || code == kVK_ForwardDelete, mods == [.option] || mods == [.command] {
      if let id = selected { delete(id) }
      return nil
    }
    if mods == [.control], chars == "n" { move(1); return nil }
    if mods == [.control], chars == "p" { move(-1); return nil }
    if mods == [.option], code == kVK_ANSI_P { if let id = selected { pin(id) }; return nil }
    if mods == [.command], let digit = chars.flatMap(Int.init), (1...9).contains(digit) {
      if digit <= shown.count { activate(shown[digit - 1].id) }
      return nil
    }
    if mods == [.command], chars == "c", search.currentEditor()?.selectedRange.length ?? 0 == 0, let id = selected {
      activate(id, pasting: false)
      return nil
    }
    return e
  }

  // MARK: - Rendering

  /// Draws the window into a PNG. Offscreen there is nothing behind the window to blur, so a
  /// solid stand-in is painted under the surface: the popover material is switched to it, and the
  /// glass (which draws nothing offscreen) gets it underneath.
  func render(to path: String, dark: Bool) {
    let standIn = dark ? NSColor(white: 0.135, alpha: 1) : NSColor(white: 0.965, alpha: 1)
    if let material = surface as? NSVisualEffectView {
      material.state = .inactive
      material.layer?.backgroundColor = standIn.cgColor
    }
    top = 20000
    screenFrame = NSRect(x: -12000, y: 19000, width: 4000, height: 1600)
    reload()
    select(selected, scroll: false)
    window.orderFrontRegardless()
    surface.layoutSubtreeIfNeeded()
    rows.forEach { $0.needsDisplay = true }
    let b = surface.bounds
    let cache = surface.bitmapImageRepForCachingDisplay(in: b)!
    surface.cacheDisplay(in: b, to: cache)
    let pad: CGFloat = 24, scale: CGFloat = 2
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((b.width + pad * 2) * scale),
                               pixelsHigh: Int((b.height + pad * 2) * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = NSSize(width: b.width + pad * 2, height: b.height + pad * 2)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    (dark ? NSColor(white: 0.32, alpha: 1) : NSColor(white: 0.82, alpha: 1)).setFill()
    NSRect(origin: .zero, size: out.size).fill()
    let frame = NSRect(x: pad, y: pad, width: b.width, height: b.height)
    let shape = NSBezierPath(roundedRect: frame, xRadius: Self.radius, yRadius: Self.radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    shape.addClip()
    if usesGlass && ProcessInfo.processInfo.environment["RENDER_RAW_GLASS"] == nil {
      standIn.setFill()
      frame.fill()
    }
    cache.draw(in: frame)
    NSGraphicsContext.restoreGraphicsState()
    try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }
}

/// The history window: borderless with a rounded material and a shadow that follows it, and
/// never activating the app, so the app behind keeps its menu bar and gets the paste.
final class ClipboardWindow: NSPanel {
  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: ClipboardPanel.width, height: 300),
               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    isMovableByWindowBackground = false
    level = .floating
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    // Clipboard contents stay out of screen shares unless the user opts in.
    sharingType = UserDefaults.standard.bool(forKey: "allowScreenCapture") ? .readOnly : .none
  }

  override var canBecomeKey: Bool { true }
}

// MARK: - Pieces

private enum Palette {
  /// The notch dashboard's clay.
  static let clay = NSColor(srgbRed: 0xD9 / 255.0, green: 0x8B / 255.0, blue: 0x6E / 255.0, alpha: 1)
  static var selection: NSColor { isDark ? clay.withAlphaComponent(0.2) : clay.withAlphaComponent(0.17) }
  static var hover: NSColor { NSColor.labelColor.withAlphaComponent(isDark ? 0.06 : 0.045) }
  static var tile: NSColor { NSColor.labelColor.withAlphaComponent(isDark ? 0.08 : 0.06) }
  static var keycap: NSColor { NSColor.labelColor.withAlphaComponent(isDark ? 0.1 : 0.07) }
  /// Pure black or white at 10%, the outline images take.
  static var imageEdge: NSColor { isDark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1) }
  static var isDark: Bool { NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

private final class FlippedClipView: NSView {
  override var isFlipped: Bool { true }
}

/// The search line: no border, no background, 17 pt.
private final class SearchField: NSTextField {
  init() {
    super.init(frame: .zero)
    isBordered = false
    drawsBackground = false
    focusRingType = .none
    font = .systemFont(ofSize: 17)
    textColor = .labelColor
    cell?.usesSingleLineMode = true
    cell?.wraps = false
    cell?.isScrollable = true
  }

  required init?(coder: NSCoder) { fatalError() }
}

/// A quiet borderless icon button: tertiary, a soft square on hover, clay when active.
private final class IconButton: NSButton {
  var active = false { didSet { tint() } }
  private var hovering = false { didSet { layer?.backgroundColor = hovering ? Palette.hover.cgColor : nil } }

  func configure(symbol: String, tip: String, target: AnyObject, action: Selector, size: CGFloat = 13) {
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
      .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    isBordered = false
    imagePosition = .imageOnly
    toolTip = tip
    self.target = target
    self.action = action
    wantsLayer = true
    layer?.cornerRadius = 7
    translatesAutoresizingMaskIntoConstraints = false
    widthAnchor.constraint(equalToConstant: 28).isActive = true
    heightAnchor.constraint(equalToConstant: 28).isActive = true
    tint()
  }

  private func tint() { contentTintColor = active ? Palette.clay : .tertiaryLabelColor }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }
}

/// A 1 pt rule in the separator colour, at half strength.
private final class Hairline: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.separatorColor.withAlphaComponent(0.35).setFill()
    NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
  }
}

/// The window's edge: a hairline just inside the rounded outline, so it holds on any backdrop.
private final class OutlineView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                            xRadius: ClipboardPanel.radius - 0.5, yRadius: ClipboardPanel.radius - 0.5)
    path.lineWidth = 1
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)).setStroke()
    path.stroke()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What a text entry is, for how its row shows it.
struct Snippet {
  enum Kind { case plain, code, url, color }
  let kind: Kind
  /// The URL's host, without "www.".
  var host: String?
  var rest: String?
  var color: NSColor?

  init(_ e: Clipboard.Entry) {
    let s = e.preview.trimmingCharacters(in: .whitespaces)
    let full = e.text ?? s
    if !s.contains(" "), let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme),
       let host = url.host {
      kind = .url
      self.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
      var tail = url.path + (url.query.map { "?" + $0 } ?? "")
      if tail == "/" { tail = "" }
      rest = tail
      return
    }
    if let c = Self.hexColor(s) {
      kind = .color
      color = c
      return
    }
    kind = Self.looksLikeCode(full) ? .code : .plain
  }

  static func hexColor(_ s: String) -> NSColor? {
    guard s.hasPrefix("#"), [4, 7, 9].contains(s.count) else { return nil }
    var hex = String(s.dropFirst())
    guard hex.allSatisfy(\.isHexDigit) else { return nil }
    if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
    guard let v = UInt64(hex, radix: 16) else { return nil }
    let rgba = hex.count == 8 ? v : v << 8 | 0xFF
    return NSColor(srgbRed: CGFloat(rgba >> 24 & 0xFF) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255,
                   blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
  }

  /// Braces, semicolons at line ends, arrows, or a shell command line.
  static func looksLikeCode(_ s: String) -> Bool {
    let head = String(s.prefix(2000))
    if head.contains("{") && head.contains("}") { return true }
    if head.contains("=>") || head.contains("->") || head.contains("::") || head.contains("();") { return true }
    let lines = head.split(separator: "\n")
    if lines.count > 1, lines.filter({ $0.hasSuffix(";") || $0.hasPrefix("  ") || $0.hasPrefix("\t") }).count * 2 >= lines.count {
      return true
    }
    let first = lines.first.map(String.init) ?? ""
    let commands = ["git ", "npm ", "pnpm ", "yarn ", "brew ", "cd ", "ls ", "cat ", "swift ", "cargo ", "docker ", "kubectl ",
                    "curl ", "ssh ", "sudo ", "python", "node ", "go ", "make ", "./", "$ ", "rm ", "mv ", "cp ", "grep ", "export "]
    return lines.count == 1 && commands.contains { first.hasPrefix($0) }
  }
}

/// "now", "2m", "3h", "yesterday", "Mon", "12 Nov".
private func relativeTime(_ d: Date) -> String {
  let s = Date().timeIntervalSince(d)
  if s < 60 { return "now" }
  if s < 3600 { return "\(Int(s / 60))m" }
  let cal = Calendar.current
  if cal.isDateInToday(d) { return "\(Int(s / 3600))h" }
  if cal.isDateInYesterday(d) { return "yesterday" }
  let f = DateFormatter()
  f.setLocalizedDateFormatFromTemplate(s < 6 * 86400 ? "EEE" : "d MMM")
  return f.string(from: d)
}

/// One entry: a leading visual (kind tile, swatch, thumbnail or Finder icon), the content in
/// one or two lines, then the source app and time in grey. A keycap and a menu button show on
/// the selected or hovered row.
private final class ClipRow: NSView {
  let entry: Clipboard.Entry
  private weak var panel: ClipboardPanel?
  private let chip: NSView?
  private let more = IconButton()
  private var hovering = false { didSet { update() } }
  var selected = false { didSet { if selected != oldValue { update() } } }

  override var isFlipped: Bool { true }

  init(entry e: Clipboard.Entry, shortcut: Int?, thumb: NSImage?, app: (name: String, icon: NSImage)?, width: CGFloat,
       text: Snippet?, panel: ClipboardPanel) {
    entry = e
    self.panel = panel
    chip = shortcut.map { ClipRow.keycap("⌘\($0 + 1)") }

    // Content first, to know the height.
    let primary = NSTextField(wrappingLabelWithString: "")
    primary.isSelectable = false
    primary.maximumNumberOfLines = 1
    primary.lineBreakMode = .byTruncatingTail
    primary.cell?.truncatesLastVisibleLine = true
    primary.textColor = .labelColor
    var lines = 1
    var leading: NSView
    switch e.kind {
    case .text:
      let snippet = text!
      switch snippet.kind {
      case .url:
        let a = NSMutableAttributedString(string: snippet.host ?? "", attributes: [
          .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])
        if let rest = snippet.rest, !rest.isEmpty {
          a.append(NSAttributedString(string: rest, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
          ]))
        }
        primary.attributedStringValue = a
        leading = ClipRow.tile(symbol: "link")
      case .color:
        primary.stringValue = e.preview.uppercased()
        primary.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        leading = ClipRow.swatch(snippet.color ?? .clear)
      case .code:
        // The first two non-empty lines as written, indentation trimmed.
        let source = (e.text ?? e.preview).split(separator: "\n", omittingEmptySubsequences: true)
          .prefix(2).map { $0.trimmingCharacters(in: .whitespaces) }
        primary.stringValue = source.joined(separator: "\n")
        primary.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        primary.maximumNumberOfLines = 2
        lines = 2
        leading = ClipRow.tile(symbol: "chevron.left.forwardslash.chevron.right")
      case .plain:
        primary.stringValue = e.preview
        primary.font = .systemFont(ofSize: 13)
        primary.lineBreakMode = .byWordWrapping
        primary.maximumNumberOfLines = 2
        lines = 2
        leading = ClipRow.tile(symbol: "text.alignleft")
      }
    case .image:
      primary.stringValue = "Image"
      primary.font = .systemFont(ofSize: 13)
      leading = ClipRow.picture(thumb, aspect: e.height > 0 ? CGFloat(e.width) / CGFloat(e.height) : 1.5)
    case .files:
      primary.stringValue = e.paths.count == 1 ? (e.paths[0] as NSString).lastPathComponent : "\(e.paths.count) files"
      primary.font = .systemFont(ofSize: 13)
      primary.lineBreakMode = .byTruncatingMiddle
      let iv = NSImageView(image: thumb ?? NSImage())
      iv.imageScaling = .scaleProportionallyUpOrDown
      iv.frame.size = NSSize(width: 30, height: 30)
      leading = iv
    }

    // Metadata: what it is, where it came from, when.
    var meta: [String] = []
    switch e.kind {
    case .image: if e.width > 0 { meta.append("\(e.width) × \(e.height)") }
    case .files:
      if e.paths.count == 1 {
        meta.append(((e.paths[0] as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
      } else {
        meta.append(e.paths.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
      }
    case .text:
      if text?.kind == .plain || text?.kind == .code, e.length > 200 { meta.append("\(e.length.formatted()) characters") }
    }
    if let app { meta.append(app.name) }
    meta.append(relativeTime(e.date))
    let metaLabel = NSTextField(labelWithString: meta.joined(separator: " · "))
    metaLabel.font = .systemFont(ofSize: 11)
    metaLabel.textColor = .secondaryLabelColor
    metaLabel.lineBreakMode = .byTruncatingMiddle

    let textX: CGFloat = 12 + 36 + 12
    let trailingRoom: CGFloat = 92
    let textWidth = width - textX - trailingRoom
    primary.preferredMaxLayoutWidth = textWidth
    primary.lineBreakMode = lines == 2 && text?.kind == .code ? .byTruncatingTail : primary.lineBreakMode
    let fit = primary.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 1000))
    let primaryHeight = min(ceil(fit.height), lines == 2 ? 34 : 18)
    let metaHeight: CGFloat = 14
    let block = primaryHeight + 3 + metaHeight
    let height = max(e.kind == .image ? 56 : 46, block + 18)
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    wantsLayer = true
    layer?.cornerRadius = 10 // 18 outside, 8 inset
    layer?.cornerCurve = .continuous

    leading.frame.origin = NSPoint(x: 12 + (36 - leading.frame.width) / 2, y: (height - leading.frame.height) / 2)
    addSubview(leading)
    let y0 = (height - block) / 2
    primary.frame = NSRect(x: textX, y: y0, width: textWidth, height: primaryHeight)
    addSubview(primary)
    var metaX = textX
    if let app {
      let icon = NSImageView(image: app.icon)
      icon.imageScaling = .scaleProportionallyUpOrDown
      icon.frame = NSRect(x: textX, y: y0 + primaryHeight + 3 + 0.5, width: 13, height: 13)
      addSubview(icon)
      metaX += 17
    }
    metaLabel.frame = NSRect(x: metaX, y: y0 + primaryHeight + 3, width: textWidth - (metaX - textX), height: metaHeight)
    addSubview(metaLabel)

    // Trailing: pin, keycap, menu.
    var x = width - 10
    more.configure(symbol: "ellipsis", tip: "More", target: self, action: #selector(menuClicked), size: 12)
    more.translatesAutoresizingMaskIntoConstraints = true
    more.frame = NSRect(x: x - 28, y: (height - 28) / 2, width: 28, height: 28)
    addSubview(more)
    x -= 28 + 4
    if let chip {
      chip.frame.origin = NSPoint(x: x - chip.frame.width, y: (height - chip.frame.height) / 2)
      addSubview(chip)
      x -= chip.frame.width + 8
    }
    if e.pinned {
      let pin = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) ?? NSImage())
      pin.contentTintColor = Palette.clay
      pin.frame = NSRect(x: width - 10 - 28 + 8, y: (height - 14) / 2, width: 12, height: 14)
      pin.identifier = NSUserInterfaceItemIdentifier("pin")
      addSubview(pin)
    }
    update()
  }

  required init?(coder: NSCoder) { fatalError() }

  private static func tile(symbol: String) -> NSView {
    let v = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
    v.wantsLayer = true
    v.layer?.cornerRadius = 8
    v.layer?.cornerCurve = .continuous
    v.layer?.backgroundColor = Palette.tile.cgColor
    let iv = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage())
    iv.contentTintColor = .secondaryLabelColor
    iv.frame = v.bounds
    v.addSubview(iv)
    return v
  }

  private static func swatch(_ c: NSColor) -> NSView {
    let v = NSView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
    v.wantsLayer = true
    v.layer?.cornerRadius = 7
    v.layer?.cornerCurve = .continuous
    v.layer?.backgroundColor = c.cgColor
    v.layer?.borderWidth = 1
    v.layer?.borderColor = Palette.imageEdge.cgColor
    return v
  }

  private static func picture(_ image: NSImage?, aspect: CGFloat) -> NSView {
    let h: CGFloat = 30, w = min(42, max(26, h * aspect))
    let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    iv.image = image
    iv.imageScaling = .scaleAxesIndependently
    iv.wantsLayer = true
    iv.layer?.cornerRadius = 6
    iv.layer?.cornerCurve = .continuous
    iv.layer?.masksToBounds = true
    iv.layer?.borderWidth = 1
    iv.layer?.borderColor = Palette.imageEdge.cgColor
    if image == nil { iv.layer?.backgroundColor = Palette.tile.cgColor }
    return iv
  }

  static func keycap(_ text: String) -> NSView {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: 10.5, weight: .medium)
    l.textColor = .secondaryLabelColor
    l.sizeToFit()
    let v = NSView(frame: NSRect(x: 0, y: 0, width: l.frame.width + 10, height: 18))
    v.wantsLayer = true
    v.layer?.cornerRadius = 5
    v.layer?.backgroundColor = Palette.keycap.cgColor
    l.frame.origin = NSPoint(x: 5, y: (18 - l.frame.height) / 2)
    v.addSubview(l)
    return v
  }

  private func update() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = (selected ? Palette.selection : hovering ? Palette.hover : .clear).cgColor
    }
    let active = selected || hovering
    chip?.isHidden = !active
    more.isHidden = !hovering
    subviews.first { $0.identifier?.rawValue == "pin" }?.isHidden = hovering
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self))
  }

  override func mouseEntered(with event: NSEvent) {
    hovering = true
    panel?.hovered(entry.id)
  }

  override func mouseExited(with event: NSEvent) { hovering = false }
  override func mouseUp(with event: NSEvent) { panel?.activate(entry.id) }
  override func mouseDown(with event: NSEvent) {}
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func rightMouseDown(with event: NSEvent) {
    guard let m = panel?.menu(for: entry.id) else { return }
    NSMenu.popUpContextMenu(m, with: event, for: self)
  }

  @objc private func menuClicked(_ sender: NSButton) {
    panel?.menu(for: entry.id).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }
}

private final class EmptyState: NSView {
  override var isFlipped: Bool { true }

  init(title: String, hint: String, symbol: NSImage) {
    super.init(frame: .zero)
    let icon = NSImageView(image: symbol)
    icon.contentTintColor = .tertiaryLabelColor
    let t = NSTextField(labelWithString: title)
    t.font = .systemFont(ofSize: 13, weight: .medium)
    t.textColor = .secondaryLabelColor
    let h = NSTextField(labelWithString: hint)
    h.font = .systemFont(ofSize: 11.5)
    h.textColor = .tertiaryLabelColor
    let stack = NSStackView(views: [icon, t, h])
    stack.orientation = .vertical
    stack.spacing = 4
    stack.setCustomSpacing(12, after: icon)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    stack.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
    stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -4).isActive = true
  }

  required init?(coder: NSCoder) { fatalError() }
}

/// The selected entry in full: text in a scrolling view, the image, or the files.
private final class PreviewPane: NSView {
  init(entry: Clipboard.Entry?, clipboard: Clipboard, thumb: NSImage?) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.025).cgColor
    let rule = Hairline()
    rule.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rule)
    rule.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
    rule.topAnchor.constraint(equalTo: topAnchor).isActive = true
    rule.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    rule.widthAnchor.constraint(equalToConstant: 1).isActive = true
    guard let e = entry else {
      let l = NSTextField(labelWithString: "Nothing selected")
      l.font = .systemFont(ofSize: 12)
      l.textColor = .tertiaryLabelColor
      l.translatesAutoresizingMaskIntoConstraints = false
      addSubview(l)
      l.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
      l.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
      return
    }
    let info = NSTextField(labelWithString: "")
    info.font = .systemFont(ofSize: 11, weight: .medium)
    info.textColor = .secondaryLabelColor
    info.translatesAutoresizingMaskIntoConstraints = false
    addSubview(info)
    let body: NSView
    switch e.kind {
    case .text:
      let text = clipboard.fullText(e) ?? e.preview
      let snippet = Snippet(e)
      info.stringValue = "\(["Text", "Code", "Link", "Colour"][[.plain, .code, .url, .color].firstIndex(of: snippet.kind)!])"
        + " · \(e.length.formatted()) characters"
      let sv = NSTextView.scrollableTextView()
      sv.drawsBackground = false
      sv.scrollerStyle = .overlay
      if let tv = sv.documentView as? NSTextView {
        tv.isEditable = false
        tv.drawsBackground = false
        tv.font = snippet.kind == .plain ? .systemFont(ofSize: 13) : .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 8, height: 4)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = snippet.kind == .plain ? 1.25 : 1.15
        tv.defaultParagraphStyle = style
        // A very long text is shown in part; the paste is always whole.
        tv.string = text.count > 100_000 ? String(text.prefix(100_000)) + "\n…" : text
      }
      body = sv
    case .image:
      info.stringValue = "Image · \(e.width) × \(e.height)"
      let iv = NSImageView()
      iv.imageScaling = .scaleProportionallyDown
      iv.wantsLayer = true
      iv.layer?.cornerRadius = 8
      iv.layer?.masksToBounds = true
      iv.image = e.blob.flatMap { NSImage(contentsOf: Clipboard.blobs.appendingPathComponent($0)) } ?? thumb
      body = iv
    case .files:
      info.stringValue = e.paths.count == 1 ? "File" : "\(e.paths.count) files"
      let l = NSTextField(wrappingLabelWithString: e.paths.map { ($0 as NSString).abbreviatingWithTildeInPath }
        .joined(separator: "\n"))
      l.font = .systemFont(ofSize: 12)
      l.textColor = .labelColor
      l.lineBreakMode = .byTruncatingMiddle
      body = l
    }
    body.translatesAutoresizingMaskIntoConstraints = false
    addSubview(body)
    NSLayoutConstraint.activate([
      info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
      info.topAnchor.constraint(equalTo: topAnchor, constant: 14),
      body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      body.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 8),
      e.kind == .files ? body.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
        : body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }
}
