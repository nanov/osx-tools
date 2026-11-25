import AppKit
import os

private let log = Logger(subsystem: "dev.nanov.osx-utils", category: "keys")

/// Brightness keys follow the pointer: on an external monitor they drive it (DDC or software
/// dimming) with our indicator; on the built-in display they pass through to macOS untouched,
/// so it keeps its own animation and indicator.
final class BrightnessKeys {
  private let brightness: Brightness
  private var tap: CFMachPort?
  /// Key codes whose key-down we swallowed; their key-up is swallowed too.
  private var swallowed: Set<Int> = []
  /// Called when a brightness key goes through to macOS for the built-in display.
  var onSystemBrightnessKey: (() -> Void)?
  /// Gets first say on built-in display keys (up, step unit); true means it handled the key.
  var onBuiltInKey: ((Bool, Double) -> Bool)?

  private static let up = 2, down = 3 // NX_KEYTYPE_BRIGHTNESS_UP / DOWN

  init(brightness: Brightness) {
    self.brightness = brightness
  }

  var isRunning: Bool { tap != nil }

  /// Needs Accessibility; logs and leaves `isRunning` false if the tap couldn't be created.
  func start() {
    guard tap == nil else { return }
    let mask = CGEventMask(1) << 14 // NX_SYSDEFINED
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
      callback: { _, type, event, info in
        let me = Unmanaged<BrightnessKeys>.fromOpaque(info!).takeUnretainedValue()
        return me.handle(type, event)
      },
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      log.notice("brightness key tap failed; accessibility trusted=\(AXIsProcessTrusted())")
      return
    }
    log.notice("brightness key tap started")
    self.tap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
  }

  private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
      return Unmanaged.passUnretained(event)
    }
    let key = (ns.data1 >> 16) & 0xFFFF
    guard key == Self.up || key == Self.down else { return Unmanaged.passUnretained(event) }
    let isDown = (ns.data1 >> 8) & 0xFF == 0x0A

    if !isDown {
      return swallowed.remove(key) != nil ? nil : Unmanaged.passUnretained(event)
    }
    // ⌥⇧ gives quarter steps, as macOS does.
    let fine = event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift)
    let unit = fine ? 1.0 / 64 : 1.0 / 16
    guard let d = brightness.displayUnderPointer, !d.isBuiltIn else {
      if onBuiltInKey?(key == Self.up, unit) == true {
        swallowed.insert(key)
        return nil
      }
      onSystemBrightnessKey?()
      return Unmanaged.passUnretained(event)
    }
    if case .system = d.route { return Unmanaged.passUnretained(event) }

    swallowed.insert(key)
    brightness.step(d, up: key == Self.up, unit: unit)
    return nil
  }
}
