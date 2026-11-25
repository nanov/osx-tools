import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey: no event tap, no permission, no polling.
final class HotKeys {
  static let shared = HotKeys()

  private var refs: [EventHotKeyRef] = []
  private var handlers: [UInt32: () -> Void] = [:]
  private var nextID: UInt32 = 1

  private init() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
      var hk = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
      HotKeys.shared.handlers[hk.id]?()
      return noErr
    }, 1, &spec, nil, nil)
  }

  /// Returns nil on success, or a human-readable error.
  func register(_ keys: String, _ handler: @escaping () -> Void) -> String? {
    guard let (code, mods) = parse(keys) else { return "\(keys): can't parse" }
    let id = nextID
    nextID += 1
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(code, mods, EventHotKeyID(signature: 0x4F53_5855, id: id),
                                     GetApplicationEventTarget(), 0, &ref)
    guard status == noErr, let ref else {
      return status == eventHotKeyExistsErr ? "\(keys): taken by another app" : "\(keys): error \(status)"
    }
    refs.append(ref)
    handlers[id] = handler
    return nil
  }

  func unregisterAll() {
    refs.forEach { UnregisterEventHotKey($0) }
    refs.removeAll()
    handlers.removeAll()
  }

  private func parse(_ s: String) -> (UInt32, UInt32)? {
    var mods: UInt32 = 0
    var code: UInt32?
    for part in s.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
      switch part {
      case "cmd", "command": mods |= UInt32(cmdKey)
      case "ctrl", "control": mods |= UInt32(controlKey)
      case "alt", "opt", "option": mods |= UInt32(optionKey)
      case "shift": mods |= UInt32(shiftKey)
      default:
        guard code == nil, let c = keyCodes[part] else { return nil }
        code = c
      }
    }
    return code.map { ($0, mods) }
  }

  // Physical (ANSI) key positions, so bindings work under any input layout.
  private let keyCodes: [String: UInt32] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
    "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
    "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
    "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
    "[": 0x21, "i": 0x22, "p": 0x23, "return": 0x24, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28,
    ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "tab": 0x30,
    "space": 0x31, "`": 0x32, "delete": 0x33, "escape": 0x35,
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
    "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    "home": 0x73, "pageup": 0x74, "end": 0x77, "pagedown": 0x79,
    "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
  ]
}
