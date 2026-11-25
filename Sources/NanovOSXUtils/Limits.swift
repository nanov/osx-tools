import Foundation

/// The plan limits `/usage` shows (weekly, per model, the five-hour session, extra usage),
/// asked of the `claude` CLI over its stream-json control protocol. The CLI answers from its
/// own sign-in; this app never sees a token. No model call is made.
///
/// A check runs only when the dashboard opens and the last reading is over a minute old.
/// The CLI is a separate process in its own process group, killed on timeout or on `cancel()`.
final class Limits {
  struct Bar: Codable {
    var label: String
    var percent: Double
    /// 0 normal, 1 warning, 2 critical.
    var severity: Int
    var resets: Date?
  }

  struct Reading: Codable {
    var weekly: Bar?
    var session: Bar?
    var models: [Bar] = []
    /// Extra usage spent, in minor units of `currency`.
    var extraMinor: Int?
    var currency: String?
    var exponent: Int = 2
    var at: Date
  }

  private(set) var reading: Reading?
  private(set) var failed = false
  private(set) var loading = false
  var onChange: (() -> Void)?

  private var pid: pid_t = 0
  private var generation = 0
  private let lock = NSLock()
  private static let timeout: TimeInterval = 25

  private static var cacheURL: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dev.nanov.osx-utils/limits.json")
  }

  init() {
    if let data = try? Data(contentsOf: Self.cacheURL) {
      let d = JSONDecoder()
      d.dateDecodingStrategy = .secondsSince1970
      reading = try? d.decode(Reading.self, from: data)
    }
  }

  /// Starts a check unless one is running or the last reading is under a minute old.
  func refreshIfStale() {
    guard !loading else { return }
    if let r = reading, !failed, Date().timeIntervalSince(r.at) < 60 { return }
    loading = true
    generation += 1
    let gen = generation
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let result = self?.check()
      DispatchQueue.main.async {
        guard let self, gen == self.generation else { return }
        self.loading = false
        if let r = result {
          self.reading = r
          self.failed = false
          self.save(r)
        } else {
          self.failed = true
        }
        self.onChange?()
      }
    }
  }

  /// Ends a running check (the dashboard closed).
  func cancel() {
    guard loading else { return }
    generation += 1
    loading = false
    kill()
  }

  private func kill() {
    lock.lock()
    let p = pid
    lock.unlock()
    if p > 0 { Darwin.kill(-p, SIGKILL) } // the whole group: the CLI and anything it started
  }

  private func save(_ r: Reading) {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .secondsSince1970
    guard let data = try? e.encode(r) else { return }
    try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: Self.cacheURL, options: .atomic)
  }

  // MARK: - The check

  /// Where the installer, Homebrew and npm put `claude`, then the PATH.
  static func executable() -> String? {
    let home = NSHomeDirectory()
    var dirs = [home + "/.local/bin", home + "/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
    dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    dirs += [home + "/.volta/bin", home + "/.bun/bin", home + "/.npm-global/bin"]
    let fm = FileManager.default
    for d in dirs where d.hasPrefix("/") {
      let p = d + "/claude"
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: p) { return p }
    }
    return nil
  }

  /// Runs one check on the calling (background) thread. Nil on any failure.
  private func check() -> Reading? {
    guard let exe = Self.executable() else { return nil }
    let args = [exe, "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                "--mcp-config", #"{"mcpServers":{}}"#, "--setting-sources", "",
                "--settings", #"{"disableAllHooks":true}"#]
    // The CLI uses its own sign-in, not whatever account or provider launched this app.
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ANTHROPIC_") && !$0.key.hasPrefix("CLAUDE") }
    env["DISABLE_AUTOUPDATER"] = "1"
    let home = NSHomeDirectory()
    env["PATH"] = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"]
      .joined(separator: ":")

    var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0]
    guard pipe(&inPipe) == 0 else { return nil }
    guard pipe(&outPipe) == 0 else { close(inPipe[0]); close(inPipe[1]); return nil }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addchdir_np(&actions, home)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    // Its own process group, so a kill reaches its children; no fd of ours but 0–2 leaks in.
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attr, 0)
    let cArgs = args.map { strdup($0) } + [nil]
    let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    var child: pid_t = 0
    let rc = posix_spawn(&child, exe, &actions, &attr, cArgs, cEnv)
    cArgs.forEach { free($0) }
    cEnv.forEach { free($0) }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    close(inPipe[0])
    close(outPipe[1])
    let input = inPipe[1], output = outPipe[0]
    guard rc == 0 else { close(input); close(output); return nil }
    lock.lock(); pid = child; lock.unlock()
    let gen = generation
    let watchdog = DispatchWorkItem { [weak self] in self?.kill() }
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
    defer {
      watchdog.cancel()
      close(input)
      close(output)
      Darwin.kill(-child, SIGKILL)
      var status: Int32 = 0
      waitpid(child, &status, 0)
      lock.lock(); pid = 0; lock.unlock()
    }
    // The dashboard may have closed while spawning.
    if gen != generation { return nil }

    var buffer = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 16384)
    func send(_ s: String) -> Bool {
      let bytes = Array((s + "\n").utf8)
      return bytes.withUnsafeBytes { write(input, $0.baseAddress, $0.count) } == bytes.count
    }
    /// Reads lines until the control_response for `id`; returns its inner `response`.
    func response(_ id: String) -> [String: Any]? {
      let needle = Array(#""request_id":"\#(id)""#.utf8)
      while true {
        while let nl = buffer.firstIndex(of: 0x0A) {
          let line = Array(buffer[..<nl])
          buffer.removeSubrange(...nl)
          // Only lines naming the request are parsed; the rest (system init etc.) are skipped.
          guard contains(line, needle),
                let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                obj["type"] as? String == "control_response",
                let resp = obj["response"] as? [String: Any], resp["request_id"] as? String == id
          else { continue }
          guard resp["subtype"] as? String == "success" else { return nil }
          return resp["response"] as? [String: Any] ?? [:]
        }
        let n = read(output, &chunk, chunk.count)
        if n <= 0 { return nil } // EOF: exited, or killed by the watchdog
        buffer.append(contentsOf: chunk[..<n])
      }
    }
    signal(SIGPIPE, SIG_IGN)
    guard send(#"{"type":"control_request","request_id":"initialize","request":{"subtype":"initialize"}}"#),
          response("initialize") != nil,
          send(#"{"type":"control_request","request_id":"usage","request":{"subtype":"get_usage","skip_behaviors":true}}"#),
          let usage = response("usage")
    else { return nil }
    return Self.parse(usage)
  }

  private func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
    guard hay.count >= needle.count else { return false }
    return hay.withUnsafeBytes { h in needle.withUnsafeBytes { n in
      memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
    } }
  }

  // MARK: - Parsing

  private static func date(_ v: Any?) -> Date? {
    guard let s = v as? String else { return (v as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
  }

  private static func severity(_ v: Any?, percent: Double) -> Int {
    switch v as? String {
    case "critical", "error", "exceeded": return 2
    case "warning": return 1
    case .some: return 0
    case nil: return percent >= 95 ? 2 : percent >= 80 ? 1 : 0
    }
  }

  static func parse(_ r: [String: Any]) -> Reading? {
    if r["rate_limits_available"] as? Bool == false { return nil }
    guard let rl = r["rate_limits"] as? [String: Any] else { return nil }
    var out = Reading(at: Date())
    if let limits = rl["limits"] as? [[String: Any]], !limits.isEmpty {
      for l in limits {
        let pct = (l["percent"] as? NSNumber)?.doubleValue ?? 0
        let bar = Bar(label: "", percent: pct, severity: severity(l["severity"], percent: pct), resets: date(l["resets_at"]))
        let kind = l["kind"] as? String ?? ""
        if kind == "weekly_all" {
          out.weekly = bar
        } else if kind.contains("scoped") {
          let scope = l["scope"] as? [String: Any]
          let name = (scope?["model"] as? [String: Any])?["display_name"] as? String ?? "Model"
          var b = bar
          b.label = name
          out.models.append(b)
        } else if kind.contains("five_hour") || kind.contains("session") {
          out.session = bar
        }
      }
    }
    func window(_ key: String) -> Bar? {
      guard let w = rl[key] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
      return Bar(label: "", percent: u, severity: severity(w["severity"], percent: u), resets: date(w["resets_at"]))
    }
    if out.weekly == nil { out.weekly = window("seven_day") }
    if out.session == nil { out.session = window("five_hour") }
    if out.models.isEmpty, let ms = rl["model_scoped"] as? [[String: Any]] {
      for m in ms {
        let u = (m["utilization"] as? NSNumber)?.doubleValue ?? 0
        out.models.append(Bar(label: m["display_name"] as? String ?? "Model", percent: u,
                              severity: severity(m["severity"], percent: u), resets: date(m["resets_at"])))
      }
    }
    if let x = rl["extra_usage"] as? [String: Any], x["is_enabled"] as? Bool == true {
      out.extraMinor = (x["used_credits"] as? NSNumber)?.intValue
      out.currency = x["currency"] as? String
      out.exponent = (x["decimal_places"] as? NSNumber)?.intValue ?? 2
    }
    return out
  }
}
