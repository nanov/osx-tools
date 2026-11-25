import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake with IOKit power assertions. They're released automatically if
/// the process exits, so a crash can't leave the Mac sleepless.
final class KeepAwake {
  private(set) var endDate: Date?
  /// Duration of the running session (nil = until turned off).
  private(set) var minutes: Int?
  private var systemID: IOPMAssertionID = 0
  private var displayID: IOPMAssertionID = 0
  private var timer: Timer?
  var onChange: (() -> Void)?

  var isActive: Bool { systemID != 0 }

  /// Also keep the display from sleeping. Persisted; applies to the running session too.
  var keepDisplayOn: Bool {
    get { UserDefaults.standard.bool(forKey: "keepDisplayOn") }
    set {
      UserDefaults.standard.set(newValue, forKey: "keepDisplayOn")
      if isActive { applyDisplay() }
    }
  }

  /// Last duration picked, used when turning on without choosing one. nil = indefinitely.
  var lastMinutes: Int? {
    get { let m = UserDefaults.standard.integer(forKey: "keepAwakeMinutes"); return m > 0 ? m : nil }
    set { UserDefaults.standard.set(newValue ?? 0, forKey: "keepAwakeMinutes") }
  }

  /// Start (or restart) a session. `minutes == nil` means until turned off.
  func start(minutes: Int?) {
    self.minutes = minutes
    if systemID == 0 { systemID = assert(kIOPMAssertPreventUserIdleSystemSleep) }
    applyDisplay()
    timer?.invalidate()
    timer = nil
    endDate = nil
    if let minutes {
      endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
      timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
        self?.stop()
      }
    }
    onChange?()
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    endDate = nil
    minutes = nil
    release(&systemID)
    release(&displayID)
    onChange?()
  }

  func toggle(minutes: Int?) { isActive ? stop() : start(minutes: minutes) }

  private func applyDisplay() {
    if keepDisplayOn, displayID == 0 { displayID = assert(kIOPMAssertPreventUserIdleDisplaySleep) }
    if !keepDisplayOn { release(&displayID) }
  }

  private func assert(_ type: String) -> IOPMAssertionID {
    var id: IOPMAssertionID = 0
    let ok = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                         "Nanov OSX Utils: Keep Awake" as CFString, &id)
    return ok == kIOReturnSuccess ? id : 0
  }

  private func release(_ id: inout IOPMAssertionID) {
    if id != 0 { IOPMAssertionRelease(id) }
    id = 0
  }
}
