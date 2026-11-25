import Foundation

enum Direction: String, Decodable { case left, right, up, down }

enum Action {
  case focusScreen(Direction)
  case moveWindowToScreen(Direction)
  case focusApp(String)
  case toggleKeepAwake(minutes: Int?)
  case clipboardHistory
  case pastePlain
}

struct Binding: Decodable {
  let keys: String
  let action: Action

  private enum K: CodingKey { case keys, action, direction, app, minutes }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: K.self)
    keys = try c.decode(String.self, forKey: .keys)
    let name = try c.decode(String.self, forKey: .action)
    switch name {
    case "focusScreen": action = .focusScreen(try c.decode(Direction.self, forKey: .direction))
    case "moveWindowToScreen": action = .moveWindowToScreen(try c.decode(Direction.self, forKey: .direction))
    case "focusApp": action = .focusApp(try c.decode(String.self, forKey: .app))
    case "toggleKeepAwake": action = .toggleKeepAwake(minutes: try c.decodeIfPresent(Int.self, forKey: .minutes))
    case "clipboardHistory": action = .clipboardHistory
    case "pastePlain": action = .pastePlain
    default:
      throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "unknown action '\(name)'")
    }
  }
}

struct Config: Decodable {
  let bindings: [Binding]

  /// Bindings a config written before these actions existed still gets.
  static let implicit: [(keys: String, action: Action)] = [
    ("ctrl+v", .clipboardHistory), ("shift+alt+cmd+v", .pastePlain),
  ]

  static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/osx-utils")
  static let url = dir.appendingPathComponent("config.json")

  static func load() throws -> Config {
    if !FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data(defaultJSON.utf8).write(to: url)
    }
    return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
  }

  static let defaultJSON = """
  {
    "bindings": [
      { "keys": "ctrl+cmd+left",      "action": "focusScreen",        "direction": "left"  },
      { "keys": "ctrl+cmd+right",     "action": "focusScreen",        "direction": "right" },
      { "keys": "ctrl+cmd+up",        "action": "focusScreen",        "direction": "up"    },
      { "keys": "ctrl+cmd+down",      "action": "focusScreen",        "direction": "down"  },
      { "keys": "ctrl+alt+cmd+left",  "action": "moveWindowToScreen", "direction": "left"  },
      { "keys": "ctrl+alt+cmd+right", "action": "moveWindowToScreen", "direction": "right" },
      { "keys": "ctrl+alt+cmd+up",    "action": "moveWindowToScreen", "direction": "up"    },
      { "keys": "ctrl+alt+cmd+down",  "action": "moveWindowToScreen", "direction": "down"  },
      { "keys": "ctrl+cmd+t",         "action": "focusApp", "app": "com.mitchellh.ghostty" },
      { "keys": "ctrl+cmd+s",         "action": "focusApp", "app": "com.tinyspeck.slackmacgap" },
      { "keys": "ctrl+alt+cmd+k",     "action": "toggleKeepAwake" },
      { "keys": "ctrl+v",             "action": "clipboardHistory" },
      { "keys": "shift+alt+cmd+v",    "action": "pastePlain" }
    ]
  }

  """
}

/// Watches the config directory (atomic saves) and the file itself (in-place writes).
final class ConfigWatcher {
  private var sources: [DispatchSourceFileSystemObject] = []
  private var pending: DispatchWorkItem?
  private let onChange: () -> Void

  init(onChange: @escaping () -> Void) {
    self.onChange = onChange
    arm()
  }

  private func arm() {
    sources.forEach { $0.cancel() }
    sources = [Config.dir.path, Config.url.path].compactMap(watch)
  }

  private func watch(_ path: String) -> DispatchSourceFileSystemObject? {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return nil }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
    src.setEventHandler { [weak self] in self?.fire() }
    src.setCancelHandler { close(fd) }
    src.resume()
    return src
  }

  private func fire() {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      arm() // the file may have been replaced; re-open it
      onChange()
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }
}
