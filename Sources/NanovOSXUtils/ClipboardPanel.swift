import AppKit
import Carbon.HIToolbox

/// The ⌃V clipboard history window: a search field over a list of pinned and recent entries,
/// an optional preview pane, and a footer. Built on open, released on close.
///
/// Keys: ↑/↓ or ⌃P/⌃N move; Return pastes into the app that was in front; ⇧Return only copies;
/// ⌥Return pastes as plain text; ⌘1…⌘9 paste the first nine; ⌥P pins; ⌥⌫ or ⌘⌫ deletes;
/// Space (after moving with the arrows) toggles the preview; Esc closes. Typing searches.
final class ClipboardPanel: NSObject, NSSearchFieldDelegate {
  private let clipboard: Clipboard
  private let window: ClipboardWindow
  private let effect = NSVisualEffectView()
  private let search = NSSearchField()
  private let previewButton = NSButton()
  private let scroll = NSScrollView()
  private let list = FlippedClipView()
  private let footerCount = NSTextField(labelWithString: "")
  private let clearButton = NSButton()
  private var preview: NSView?
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
  private let target: NSRunningApplication?
  var onClose: (() -> Void)?

  static let size = NSSize(width: 560, height: 420)
  static let previewExtra = NSSize(width: 280, height: 80)

  init(clipboard: Clipboard, appearance: NSAppearance? = nil) {
    self.clipboard = clipboard
    let front = NSWorkspace.shared.frontmostApplication
    target = front?.bundleIdentifier != Bundle.main.bundleIdentifier && front?.activationPolicy == .regular ? front : nil
    window = ClipboardWindow()
    super.init()
    window.appearance = appearance
    build()
  }

  // MARK: - Open / close

  func show() {
    position()
    window.orderFrontRegardless()
    window.makeKey()
    window.makeFirstResponder(search)
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
    window.contentView = nil
    window.close()
    // Hand the pages the views used back to the system rather than keep them for next time.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { malloc_zone_pressure_relief(nil, 0) }
    rows = []
    thumbs = [:]
    onClose?()
    onClose = nil
  }

  /// On the screen under the pointer, centred, a little below the top.
  private func position() {
    let mouse = NSEvent.mouseLocation
    let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
    var size = Self.size
    if previewOn { size.width += Self.previewExtra.width; size.height += Self.previewExtra.height }
    size = NSSize(width: min(size.width, screen.width - 32), height: min(size.height, screen.height - 32))
    let x = screen.midX - size.width / 2
    let y = min(screen.maxY - size.height - 54, screen.midY - size.height / 2)
    window.setFrame(NSRect(x: x, y: max(screen.minY + 16, y), width: size.width, height: size.height), display: true)
  }

  // MARK: - Layout

  private func build() {
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    window.contentView = effect

    search.placeholderString = "Search"
    search.delegate = self
    search.focusRingType = .none
    search.font = .systemFont(ofSize: 13)

    previewButton.bezelStyle = .rounded
    previewButton.controlSize = .small
    previewButton.target = self
    previewButton.action = #selector(togglePreview)
    previewButton.imagePosition = .imageLeading
    previewButton.title = "Preview"
    previewButton.toolTip = "Preview (Space)"

    let closeButton = NSButton(image: symbol("xmark", 10.5, .semibold), target: self, action: #selector(closeClicked))
    closeButton.isBordered = false
    closeButton.contentTintColor = .secondaryLabelColor
    closeButton.toolTip = "Close (Esc)"

    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.verticalScrollElasticity = .none
    scroll.documentView = list

    clearButton.title = "Clear Recent"
    clearButton.image = symbol("trash", 11, .regular)
    clearButton.imagePosition = .imageLeading
    clearButton.bezelStyle = .rounded
    clearButton.controlSize = .small
    clearButton.target = self
    clearButton.action = #selector(clearClicked)
    footerCount.font = .systemFont(ofSize: 10.5, weight: .medium)
    footerCount.textColor = .secondaryLabelColor
    let countIcon = NSImageView(image: symbol("doc.on.clipboard", 10.5, .medium))
    countIcon.contentTintColor = .secondaryLabelColor

    for v in [search, previewButton, closeButton, scroll, clearButton, footerCount, countIcon] as [NSView] {
      v.translatesAutoresizingMaskIntoConstraints = false
      effect.addSubview(v)
    }
    let top = separator(), bottom = separator()
    let previewHost = NSView()
    previewHost.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(previewHost)
    self.previewHost = previewHost
    let previewWidth = previewHost.widthAnchor.constraint(equalToConstant: previewOn ? 280 : 0)
    self.previewWidth = previewWidth
    NSLayoutConstraint.activate([
      search.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
      search.topAnchor.constraint(equalTo: effect.topAnchor, constant: 9),
      previewButton.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 8),
      previewButton.centerYAnchor.constraint(equalTo: search.centerYAnchor),
      closeButton.leadingAnchor.constraint(equalTo: previewButton.trailingAnchor, constant: 8),
      closeButton.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
      closeButton.centerYAnchor.constraint(equalTo: search.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 22),
      top.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      top.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      top.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 9),
      scroll.topAnchor.constraint(equalTo: top.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor),
      previewHost.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
      previewHost.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      previewHost.topAnchor.constraint(equalTo: top.bottomAnchor),
      previewHost.bottomAnchor.constraint(equalTo: bottom.topAnchor),
      previewWidth,
      bottom.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      bottom.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      bottom.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -36),
      clearButton.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
      clearButton.centerYAnchor.constraint(equalTo: effect.bottomAnchor, constant: -18),
      footerCount.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
      footerCount.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
      countIcon.trailingAnchor.constraint(equalTo: footerCount.leadingAnchor, constant: -5),
      countIcon.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
    ])
    updatePreviewButton()
    reload()
  }

  private var previewHost: NSView?
  private var previewWidth: NSLayoutConstraint?

  private func separator() -> NSBox {
    let b = NSBox()
    b.boxType = .separator
    b.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(b)
    return b
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
    footerCount.stringValue = "\(all.count)"
    clearButton.isEnabled = all.contains { !$0.pinned }
    layoutList(grouped: tokens.isEmpty)
    updatePreview()
  }

  private func layoutList(grouped: Bool) {
    list.subviews.forEach { $0.removeFromSuperview() }
    rows = []
    let width = max(scroll.contentSize.width, 200)
    var y: CGFloat = 6
    if shown.isEmpty {
      let empty = EmptyState(message: clipboard.entries.isEmpty ? "No clipboard history yet" : "No results",
                             symbol: symbol("doc.on.clipboard", 27, .light))
      empty.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, 200))
      list.addSubview(empty)
      list.frame = empty.frame
      return
    }
    let pinned = grouped ? shown.filter(\.pinned) : []
    let recent = grouped ? shown.filter { !$0.pinned } : shown
    func section(_ title: String?, _ entries: [Clipboard.Entry], rule: Bool) {
      guard !entries.isEmpty else { return }
      if rule {
        let b = NSBox(frame: NSRect(x: 16, y: y + 5, width: width - 32, height: 1))
        b.boxType = .separator
        list.addSubview(b)
        y += 11
      }
      if let title {
        let h = NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: [
          .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
          .kern: 0.6,
        ]))
        h.sizeToFit()
        h.frame.origin = NSPoint(x: 18, y: y + 6)
        list.addSubview(h)
        y += h.frame.height + 12
      }
      for (i, e) in entries.enumerated() {
        let index = shown.prefix(9).firstIndex { $0.id == e.id }
        let row = ClipRow(entry: e, shortcut: index, thumb: thumb(e), width: width - 20, panel: self)
        row.frame.origin = NSPoint(x: 10, y: y)
        row.selected = e.id == selected
        list.addSubview(row)
        rows.append(row)
        y += row.frame.height
        if i < entries.count - 1 {
          let b = NSBox(frame: NSRect(x: 10 + 43, y: y, width: width - 20 - 51, height: 1))
          b.boxType = .separator
          b.alphaValue = 0.6
          list.addSubview(b)
        }
      }
    }
    section(grouped ? "Pinned" : nil, pinned, rule: false)
    section(grouped ? "Recent" : nil, recent, rule: !pinned.isEmpty)
    list.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 6, scroll.contentSize.height))
  }

  private func thumb(_ e: Clipboard.Entry) -> NSImage? {
    if let t = thumbs[e.id] { return t }
    var image: NSImage?
    if e.kind == .image {
      image = NSImage(contentsOf: Clipboard.thumbs.appendingPathComponent(e.id.uuidString + ".png"))
    } else if e.kind == .files, let p = e.paths.first, FileManager.default.fileExists(atPath: p) {
      image = NSWorkspace.shared.icon(forFile: p)
    }
    thumbs[e.id] = image
    return image
  }

  // MARK: - Selection and actions

  private func select(_ id: UUID?, scroll toVisible: Bool = true) {
    selected = id
    for r in rows { r.selected = r.entry.id == id }
    if toVisible, let r = rows.first(where: { $0.entry.id == id }) {
      list.scrollToVisible(r.frame.insetBy(dx: 0, dy: -6))
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

  private func setPreview(_ on: Bool, remember: Bool) {
    guard on != previewOn else { return }
    previewOn = on
    if remember { UserDefaults.standard.set(previewOn, forKey: "clipboardPreview") }
    var f = window.frame
    let dx = Self.previewExtra.width * (previewOn ? 1 : -1), dy = Self.previewExtra.height * (previewOn ? 1 : -1)
    f = NSRect(x: f.minX - dx / 2, y: f.minY - dy / 2, width: f.width + dx, height: f.height + dy)
    previewWidth?.constant = previewOn ? 280 : 0
    window.setFrame(f, display: true)
    effect.layoutSubtreeIfNeeded()
    updatePreviewButton()
    layoutList(grouped: search.stringValue.isEmpty)
    select(selected)
  }

  private func updatePreviewButton() {
    previewButton.image = symbol(previewOn ? "sidebar.right" : "eye", 11, .regular)
    previewButton.contentTintColor = previewOn ? .controlAccentColor : .secondaryLabelColor
  }

  private func updatePreview() {
    preview?.removeFromSuperview()
    preview = nil
    guard previewOn, let host = previewHost else { return }
    let divider = NSBox()
    divider.boxType = .separator
    let pane = PreviewPane(entry: shown.first { $0.id == selected }, clipboard: clipboard)
    for v in [divider, pane] as [NSView] {
      v.translatesAutoresizingMaskIntoConstraints = false
      host.addSubview(v)
    }
    NSLayoutConstraint.activate([
      divider.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      divider.topAnchor.constraint(equalTo: host.topAnchor),
      divider.bottomAnchor.constraint(equalTo: host.bottomAnchor),
      divider.widthAnchor.constraint(equalToConstant: 1),
      pane.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
      pane.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      pane.topAnchor.constraint(equalTo: host.topAnchor),
      pane.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
    preview = pane
    // Both go when the next preview replaces this one.
    pane.companion = divider
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
    switch Int(e.keyCode) {
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
    case kVK_Delete, kVK_ForwardDelete where mods == [.option] || mods == [.command]:
      if let id = selected { delete(id) }
      return nil
    default: break
    }
    if mods == [.control], chars == "n" { move(1); return nil }
    if mods == [.control], chars == "p" { move(-1); return nil }
    if mods == [.option], Int(e.keyCode) == kVK_ANSI_P { if let id = selected { pin(id) }; return nil }
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

  /// Draws the window's content into a PNG (dark appearance, solid background).
  func render(to path: String) {
    position()
    effect.state = .inactive
    effect.wantsLayer = true
    effect.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
    window.setFrame(NSRect(origin: NSPoint(x: -10000, y: 0), size: window.frame.size), display: true)
    window.orderFrontRegardless()
    effect.layoutSubtreeIfNeeded()
    layoutList(grouped: true)
    select(selected)
    let rep = effect.bitmapImageRepForCachingDisplay(in: effect.bounds)!
    effect.cacheDisplay(in: effect.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }

  func setSampleThumb(_ id: UUID, _ image: NSImage) { thumbs[id] = image }
  func setSamplePreview(_ on: Bool) { setPreview(on, remember: false) }
}

/// The history window: titled (rounded, with a shadow) but chromeless, and never activating
/// the app, so the app behind keeps its menu bar and gets the paste.
final class ClipboardWindow: NSPanel {
  init() {
    super.init(contentRect: NSRect(origin: .zero, size: ClipboardPanel.size),
               styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    isMovableByWindowBackground = false
    level = .floating
    animationBehavior = .utilityWindow
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    // Clipboard contents stay out of screen shares unless the user opts in.
    sharingType = UserDefaults.standard.bool(forKey: "allowScreenCapture") ? .readOnly : .none
  }

  override var canBecomeKey: Bool { true }
}

private final class FlippedClipView: NSView {
  override var isFlipped: Bool { true }
}

/// One entry: kind symbol (or pin), content, and the time with its ⌘ number; on hover, a copy
/// button and a menu.
private final class ClipRow: NSView {
  let entry: Clipboard.Entry
  private weak var panel: ClipboardPanel?
  private let trailing = NSStackView()
  private let actions = NSStackView()
  private var hovering = false { didSet { update() } }
  var selected = false { didSet { if selected != oldValue { update() } } }

  override var isFlipped: Bool { true }

  private static let time: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    f.doesRelativeDateFormatting = true
    return f
  }()

  init(entry e: Clipboard.Entry, shortcut: Int?, thumb: NSImage?, width: CGFloat, panel: ClipboardPanel) {
    entry = e
    self.panel = panel
    let picture = e.kind == .image
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: picture ? 60 : 48))
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1

    // Leading marker.
    let marker: NSImageView
    if e.kind == .files, let thumb {
      marker = NSImageView(image: thumb)
      marker.imageScaling = .scaleProportionallyUpOrDown
      marker.frame = NSRect(x: 8 + 2.5, y: (frame.height - 20) / 2, width: 20, height: 20)
    } else {
      let name = e.pinned ? "pin.fill" : ["text": "doc.text", "image": "photo", "files": "folder"][e.kind.rawValue]!
      let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) ?? NSImage()
      marker = NSImageView(image: img)
      marker.contentTintColor = e.pinned ? .controlAccentColor : .secondaryLabelColor
      marker.frame = NSRect(x: 8, y: (frame.height - 25) / 2, width: 25, height: 25)
    }
    addSubview(marker)

    // Content.
    var x: CGFloat = 8 + 25 + 9
    let right = width - 8 - 70
    if picture {
      let iv = NSImageView()
      iv.image = thumb
      iv.imageScaling = .scaleProportionallyUpOrDown
      iv.wantsLayer = true
      iv.layer?.cornerRadius = 6
      iv.layer?.masksToBounds = true
      let aspect = e.height > 0 ? CGFloat(e.width) / CGFloat(e.height) : 1.5
      let h: CGFloat = 44, w = min(80, h * aspect)
      iv.frame = NSRect(x: x, y: (frame.height - h) / 2, width: w, height: h)
      if thumb == nil {
        iv.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
      }
      addSubview(iv)
      x += w + 9
    }
    let title: String
    var subtitle: String?
    switch e.kind {
    case .text: title = e.preview
    case .image: title = e.width > 0 ? "Image · \(e.width) × \(e.height)" : "Image"
    case .files:
      title = e.paths.count == 1 ? (e.paths[0] as NSString).lastPathComponent : "\(e.paths.count) files"
      if e.paths.count > 1 { subtitle = e.preview }
    }
    let label = NSTextField(wrappingLabelWithString: title)
    label.font = .systemFont(ofSize: picture ? 11.5 : 12)
    label.textColor = picture ? .secondaryLabelColor : .labelColor
    label.maximumNumberOfLines = e.kind == .text ? 2 : 1
    label.lineBreakMode = e.kind == .files ? .byTruncatingMiddle : .byTruncatingTail
    label.cell?.truncatesLastVisibleLine = true
    label.isSelectable = false
    let lw = right - x
    let fit = label.sizeThatFits(NSSize(width: lw, height: 40))
    var lh = min(fit.height, e.kind == .text ? 32 : 16)
    if let subtitle {
      let s = NSTextField(labelWithString: subtitle)
      s.font = .systemFont(ofSize: 10)
      s.textColor = .tertiaryLabelColor
      s.lineBreakMode = .byTruncatingTail
      s.frame = NSRect(x: x, y: (frame.height + lh) / 2 - 6, width: lw, height: 14)
      addSubview(s)
      lh += 14
    }
    label.frame = NSRect(x: x, y: (frame.height - lh) / 2, width: lw, height: min(fit.height, e.kind == .text ? 32 : 16))
    addSubview(label)

    // Trailing: time and shortcut, or (on hover) actions.
    trailing.orientation = .vertical
    trailing.alignment = .trailing
    trailing.spacing = 3
    let t = NSTextField(labelWithString: Self.time.string(from: e.date))
    t.font = .systemFont(ofSize: 9.5)
    t.textColor = .tertiaryLabelColor
    trailing.addArrangedSubview(t)
    if let shortcut {
      let s = NSTextField(labelWithString: "⌘\(shortcut + 1)")
      s.font = NSFont(descriptor: NSFont.systemFont(ofSize: 9.5, weight: .semibold).fontDescriptor.withDesign(.rounded)!,
                      size: 9.5)
      s.textColor = .secondaryLabelColor
      trailing.addArrangedSubview(s)
    }
    let ts = trailing.fittingSize
    trailing.frame = NSRect(x: width - 8 - ts.width, y: (frame.height - ts.height) / 2, width: ts.width, height: ts.height)
    addSubview(trailing)

    actions.orientation = .horizontal
    actions.spacing = 4
    for (name, sel) in [("doc.on.doc", #selector(copyClicked)), ("ellipsis", #selector(menuClicked))] {
      let b = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold)) ?? NSImage(), target: self, action: sel)
      b.isBordered = false
      b.wantsLayer = true
      b.layer?.cornerRadius = 6
      b.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
      b.contentTintColor = .labelColor
      b.translatesAutoresizingMaskIntoConstraints = false
      b.widthAnchor.constraint(equalToConstant: 24).isActive = true
      b.heightAnchor.constraint(equalToConstant: 24).isActive = true
      b.toolTip = name == "doc.on.doc" ? "Copy" : "More"
      actions.addArrangedSubview(b)
    }
    actions.frame = NSRect(x: width - 8 - 52, y: (frame.height - 24) / 2, width: 52, height: 24)
    actions.isHidden = true
    addSubview(actions)
    update()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func update() {
    let accent = NSColor.controlAccentColor
    layer?.backgroundColor = (selected ? accent.withAlphaComponent(hovering ? 0.13 : 0.09)
      : hovering ? NSColor.labelColor.withAlphaComponent(0.055) : .clear).cgColor
    layer?.borderColor = (selected ? accent.withAlphaComponent(0.24) : .clear).cgColor
    actions.isHidden = !hovering
    trailing.isHidden = hovering
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

  @objc private func copyClicked() { panel?.activate(entry.id, pasting: false) }

  @objc private func menuClicked(_ sender: NSButton) {
    panel?.menu(for: entry.id).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }
}

private final class EmptyState: NSView {
  override var isFlipped: Bool { true }

  init(message: String, symbol: NSImage) {
    super.init(frame: .zero)
    let icon = NSImageView(image: symbol)
    icon.contentTintColor = .tertiaryLabelColor
    let label = NSTextField(labelWithString: message)
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.textColor = .secondaryLabelColor
    let stack = NSStackView(views: [icon, label])
    stack.orientation = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    stack.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
    stack.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
  }

  required init?(coder: NSCoder) { fatalError() }
}

/// The selected entry in full: text in a scrolling view, the image, or the files.
private final class PreviewPane: NSView {
  weak var companion: NSView?

  override func removeFromSuperview() {
    companion?.removeFromSuperview()
    super.removeFromSuperview()
  }

  init(entry: Clipboard.Entry?, clipboard: Clipboard) {
    super.init(frame: .zero)
    guard let e = entry else {
      let l = NSTextField(labelWithString: "Nothing selected")
      l.textColor = .secondaryLabelColor
      l.translatesAutoresizingMaskIntoConstraints = false
      addSubview(l)
      l.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
      l.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
      return
    }
    let info = NSTextField(labelWithString: "")
    info.font = .systemFont(ofSize: 10.5, weight: .medium)
    info.textColor = .secondaryLabelColor
    info.translatesAutoresizingMaskIntoConstraints = false
    addSubview(info)
    let body: NSView
    switch e.kind {
    case .text:
      let text = clipboard.fullText(e) ?? e.preview
      info.stringValue = "Text · \(e.length.formatted()) characters"
      let sv = NSTextView.scrollableTextView()
      sv.drawsBackground = false
      sv.scrollerStyle = .overlay
      if let tv = sv.documentView as? NSTextView {
        tv.isEditable = false
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 6, height: 6)
        // A very long text is shown in part; the paste is always whole.
        tv.string = text.count > 100_000 ? String(text.prefix(100_000)) + "\n…" : text
      }
      body = sv
    case .image:
      info.stringValue = "Image · \(e.width) × \(e.height)"
      let iv = NSImageView()
      iv.imageScaling = .scaleProportionallyDown
      if let blob = e.blob { iv.image = NSImage(contentsOf: Clipboard.blobs.appendingPathComponent(blob)) }
      body = iv
    case .files:
      info.stringValue = e.paths.count == 1 ? "File" : "\(e.paths.count) files"
      let l = NSTextField(wrappingLabelWithString: e.paths.joined(separator: "\n"))
      l.font = .systemFont(ofSize: 11)
      l.lineBreakMode = .byTruncatingMiddle
      body = l
    }
    body.translatesAutoresizingMaskIntoConstraints = false
    addSubview(body)
    NSLayoutConstraint.activate([
      info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      info.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      body.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 8),
      e.kind == .files ? body.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        : body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }
}
