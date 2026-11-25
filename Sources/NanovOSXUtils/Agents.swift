import AppKit

/// Live state of Claude Code sessions, pushed by Claude Code hooks over a Unix socket.
///
/// Each hook runs a one-line shell command that sends the Rex session and pane it runs in,
/// then the hook's JSON, to `~/.config/osx-utils/agents.sock`, in the background so Claude
/// Code never waits on us. Nothing here polls, except a cheap staleness check while a
/// session is working (an interrupted turn fires no hook).
final class Agents {
  enum State: Int, Comparable {
    case done, working, attention
    static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
  }

  final class Session {
    let id: String
    var cwd = ""
    var transcript = ""
    var rexSession = ""
    var rexBlock = ""
    var rexLabel: String?
    var state = State.done
    var tool: String?
    var since = Date()
    var lastEvent = Date()
    /// The `claude` process, once known; its exit removes the session.
    var pid: pid_t = 0
    /// Found running but has sent no hook yet (started before the hooks, or idle since).
    var discovered: Bool { id.hasPrefix("pid:") }
    init(id: String) { self.id = id }

    var title: String { rexLabel ?? (cwd as NSString).lastPathComponent }
  }

  private(set) var sessions: [String: Session] = [:]
  var onChange: (() -> Void)?
  /// A session's transcript may have grown (its path is passed).
  var onTranscript: ((String) -> Void)?

  /// Sessions by urgency, then most recent first.
  var sorted: [Session] {
    sessions.values.sorted { ($0.state, $0.lastEvent) > ($1.state, $1.lastEvent) }
  }

  static let socketPath = Config.url.deletingLastPathComponent().appendingPathComponent("agents.sock").path

  private var listenFD: Int32 = -1
  private var listenSource: DispatchSourceRead?
  private var staleTimer: Timer?

  // MARK: - Socket

  func start() {
    guard listenFD < 0 else { return }
    let path = Self.socketPath
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let ok = withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      path.utf8CString.withUnsafeBytes { src -> Bool in
        guard src.count <= buf.count else { return false }
        buf.copyMemory(from: src)
        return true
      }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    guard ok, withUnsafePointer(to: &addr, {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
    }) == 0, listen(fd, 16) == 0 else {
      close(fd)
      return
    }
    chmod(path, 0o600)
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    listenFD = fd
    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    src.setEventHandler { [weak self] in self?.accept() }
    src.resume()
    listenSource = src
  }

  private func accept() {
    while true {
      let c = Darwin.accept(listenFD, nil, nil)
      guard c >= 0 else { return }
      _ = fcntl(c, F_SETFL, O_NONBLOCK)
      var data = Data()
      let src = DispatchSource.makeReadSource(fileDescriptor: c, queue: .main)
      let finish = { [weak self] in
        src.cancel()
        self?.received(data)
      }
      src.setEventHandler {
        var buf = [UInt8](repeating: 0, count: 16_384)
        let n = read(c, &buf, buf.count)
        if n > 0 {
          data.append(buf, count: n)
          // The sender doesn't close its side; stop as soon as the JSON is complete.
          if data.count > 1_000_000 || Self.payload(data) != nil { finish() }
        } else if n == 0 || errno != EAGAIN {
          finish()
        }
      }
      src.setCancelHandler { close(c) }
      src.resume()
    }
  }

  /// "<rex session>\t<rex block>\n<hook json>" → (session, block, json).
  private static func payload(_ data: Data) -> (String, String, [String: Any])? {
    guard let nl = data.firstIndex(of: 0x0A) else { return nil }
    let head = String(decoding: data[..<nl], as: UTF8.self).split(separator: "\t", omittingEmptySubsequences: false)
    guard let json = try? JSONSerialization.jsonObject(with: data[data.index(after: nl)...]) as? [String: Any]
    else { return nil }
    return (head.first.map(String.init) ?? "", head.count > 1 ? String(head[1]) : "", json)
  }

  private func received(_ data: Data) {
    guard let (rexSession, rexBlock, json) = Self.payload(data),
          let id = json["session_id"] as? String, let event = json["hook_event_name"] as? String
    else { return }
    if event == "SessionEnd" {
      if let t = sessions[id]?.transcript, !t.isEmpty { onTranscript?(t) }
      sessions[id] = nil
      return changed()
    }
    let s = sessions[id] ?? Session(id: id)
    let isNew = sessions[id] == nil
    sessions[id] = s
    if let v = json["cwd"] as? String { s.cwd = v }
    if let v = json["transcript_path"] as? String { s.transcript = v }
    if !rexSession.isEmpty { s.rexSession = rexSession; s.rexBlock = rexBlock }
    s.lastEvent = Date()
    if isNew { adoptDiscovered(into: s) }

    switch event {
    case "UserPromptSubmit":
      set(s, .working)
      s.tool = nil
    case "PreToolUse":
      set(s, .working)
      s.tool = json["tool_name"] as? String
    case "PostToolUse":
      set(s, .working)
      s.tool = nil
    case "Notification":
      // Permission prompts need you now; "waiting for your input" after a finished turn
      // doesn't change anything.
      let msg = (json["message"] as? String ?? "").lowercased()
      if msg.contains("permission") || s.state == .working { set(s, .attention) }
    case "Stop":
      set(s, .done)
      s.tool = nil
    default: break // SessionStart: just registers the session
    }
    if isNew, !s.rexSession.isEmpty { resolveLabel(s) }
    if event != "SessionStart", !s.transcript.isEmpty { onTranscript?(s.transcript) }
    changed()
  }

  private func set(_ s: Session, _ state: State) {
    guard s.state != state else { return }
    s.since = Date()
    s.state = state
    // Mirror "needs you" as Rex's unread mark on the pane's tab.
    markUnread(s, state == .attention)
  }

  private func changed() {
    pruneOld()
    updateStaleTimer()
    updateRexWatchers()
    onChange?()
  }

  // MARK: - Running processes

  private var exitSources: [pid_t: DispatchSourceProcess] = [:]
  private var scanTimer: Timer?

  /// Find every running interactive `claude` and list the ones no hook has told us about,
  /// as idle. Cheap (a process list and a few sysctls); runs at start, every 30 s, and when
  /// the dashboard opens. Exits are noticed at once through kqueue.
  func scanProcesses() {
    if scanTimer == nil {
      let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.scanProcesses() }
      t.tolerance = 10
      RunLoop.main.add(t, forMode: .common)
      scanTimer = t
    }
    var any = false
    for proc in Self.claudeProcesses() {
      if sessions.values.contains(where: { $0.pid == proc.pid }) { continue }
      // A session that already reported from the same pane is this process.
      if let s = sessions.values.first(where: { $0.pid == 0 && !$0.discovered && matches($0, proc) }) {
        s.pid = proc.pid
        watchExit(proc.pid)
        continue
      }
      let s = Session(id: "pid:\(proc.pid)")
      s.pid = proc.pid
      s.cwd = proc.cwd
      s.rexSession = proc.rexSession
      s.rexBlock = proc.rexBlock
      s.since = .distantPast
      s.lastEvent = proc.started
      sessions[s.id] = s
      watchExit(proc.pid)
      if !s.rexSession.isEmpty { resolveLabel(s) }
      any = true
    }
    if any { changed() }
  }

  private func matches(_ s: Session, _ p: ClaudeProcess) -> Bool {
    if !s.rexBlock.isEmpty || !p.rexBlock.isEmpty { return s.rexBlock == p.rexBlock }
    return !s.cwd.isEmpty && s.cwd == p.cwd
  }

  /// A hooked session takes over the discovered entry for the same process.
  private func adoptDiscovered(into s: Session) {
    guard let old = sessions.values.first(where: { $0.discovered && matches($0, ClaudeProcess(
      pid: 0, cwd: s.cwd, rexSession: s.rexSession, rexBlock: s.rexBlock, started: Date())) })
    else { return }
    s.pid = old.pid
    if s.rexLabel == nil { s.rexLabel = old.rexLabel }
    sessions[old.id] = nil
  }

  private func watchExit(_ pid: pid_t) {
    guard exitSources[pid] == nil else { return }
    let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    src.setEventHandler { [weak self] in
      guard let self else { return }
      exitSources[pid]?.cancel()
      exitSources[pid] = nil
      let gone = sessions.filter { $0.value.pid == pid }.map(\.key)
      gone.forEach { self.sessions[$0] = nil }
      if !gone.isEmpty { changed() }
    }
    src.resume()
    exitSources[pid] = src
    // Exited between the scan and now: kqueue won't report it.
    if kill(pid, 0) != 0, errno == ESRCH { src.cancel(); exitSources[pid] = nil; sessions = sessions.filter { $0.value.pid != pid } }
  }

  struct ClaudeProcess {
    let pid: pid_t
    let cwd: String
    let rexSession: String
    let rexBlock: String
    let started: Date
  }

  /// Our user's interactive `claude` processes (not `--print` runs or the Chrome host).
  static func claudeProcesses() -> [ClaudeProcess] {
    var pids = [pid_t](repeating: 0, count: 4096)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard n > 0 else { return [] }
    let uid = getuid()
    var out: [ClaudeProcess] = []
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    for pid in pids.prefix(Int(n)) where pid > 0 {
      // The installer's binary is named after its version (…/claude/versions/2.1.326).
      guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
      let exe = String(cString: path)
      guard exe.hasSuffix("/claude") || exe.contains("/claude/versions/") else { continue }
      var info = proc_bsdinfo()
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
            info.pbi_uid == uid else { continue }
      guard let (args, env) = argsAndEnv(pid),
            !args.contains(where: { ["--print", "-p", "--chrome-native-host"].contains($0) }) else { continue }
      var vnode = proc_vnodepathinfo()
      var cwd = ""
      if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
        cwd = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
      }
      let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
      out.append(ClaudeProcess(pid: pid, cwd: cwd, rexSession: env["REX_SESSION"] ?? "",
                               rexBlock: env["REX_BLOCK"] ?? "", started: started))
    }
    return out
  }

  /// A process's arguments and environment (readable for our own user's processes).
  private static func argsAndEnv(_ pid: pid_t) -> ([String], [String: String])? {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = 4
    while i < size, buf[i] != 0 { i += 1 } // executable path
    var strings: [String] = []
    while i < size {
      while i < size, buf[i] == 0 { i += 1 }
      let start = i
      while i < size, buf[i] != 0 { i += 1 }
      if i > start { strings.append(String(decoding: buf[start..<i], as: UTF8.self)) }
    }
    let args = Array(strings.prefix(argc))
    var env: [String: String] = [:]
    for e in strings.dropFirst(argc) {
      guard let eq = e.firstIndex(of: "=") else { continue }
      let key = String(e[..<eq])
      if key == "REX_SESSION" || key == "REX_BLOCK" { env[key] = String(e[e.index(after: eq)...]) }
    }
    return (args, env)
  }

  // MARK: - Rex events

  /// One `rex events` stream per Rex session that has a Claude session in it, so a closed pane
  /// drops its Claude session at once. Streams end when their last Claude session goes.
  private var rexWatchers: [String: Process] = [:] {
    didSet {
      // Child processes outlive us unless stopped; end the streams when the app quits.
      guard quitObserver == nil, !rexWatchers.isEmpty else { return }
      quitObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.rexWatchers.values.forEach { $0.terminate() } }
    }
  }
  private var quitObserver: NSObjectProtocol?

  private func updateRexWatchers() {
    guard let path = Self.rexPath else { return }
    let wanted = Set(sessions.values.map(\.rexSession).filter { !$0.isEmpty })
    for (id, p) in rexWatchers where !wanted.contains(id) {
      p.terminate()
      rexWatchers[id] = nil
    }
    for id in wanted where rexWatchers[id] == nil {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: path)
      p.arguments = ["events", "-s", id, "--json"]
      let pipe = Pipe()
      p.standardOutput = pipe
      p.standardError = FileHandle.nullDevice
      var buffer = Data()
      pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
        let chunk = h.availableData
        guard !chunk.isEmpty else { h.readabilityHandler = nil; return }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
          let line = buffer[buffer.startIndex..<nl]
          buffer.removeSubrange(buffer.startIndex...nl)
          guard line.range(of: Data("block_closed".utf8)) != nil,
                let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let event = (root["payload"] as? [String: Any])?["event"] as? [String: Any],
                event["type"] as? String == "block_closed",
                let block = (event["payload"] as? [String: Any])?["block_id"] as? String
          else { continue }
          DispatchQueue.main.async { self?.blockClosed(session: id, block: block) }
        }
      }
      p.terminationHandler = { [weak self] _ in
        DispatchQueue.main.async {
          // Rex restarted or the session ended: try again on the next change.
          if self?.rexWatchers[id] === p { self?.rexWatchers[id] = nil }
        }
      }
      guard (try? p.run()) != nil else { continue }
      rexWatchers[id] = p
    }
  }

  private func blockClosed(session: String, block: String) {
    let gone = sessions.filter { $0.value.rexSession == session && $0.value.rexBlock == block }.map(\.key)
    guard !gone.isEmpty else { return }
    gone.forEach { sessions[$0] = nil }
    changed()
  }

  /// Rex's unread mark for the tab holding the session's pane.
  private func markUnread(_ s: Session, _ unread: Bool) {
    guard !s.rexSession.isEmpty, !s.rexBlock.isEmpty else { return }
    let block = s.rexBlock
    DispatchQueue.global(qos: .utility).async {
      var args = Self.liveRexApp().map { ["-C", $0] } ?? []
      args += ["do", "client.tab.unread", "block_id=\(block)", "unread=\(unread)"]
      Self.rex(args)
    }
  }

  /// Sessions that ended without telling us (terminal closed, crash).
  private func pruneOld() {
    let cutoff = Date().addingTimeInterval(-12 * 3600)
    sessions = sessions.filter { $0.value.pid != 0 || $0.value.lastEvent > cutoff }
  }

  // MARK: - Interrupted turns

  /// Esc fires no hook, so a "working" session that stops writing its transcript is done.
  private func updateStaleTimer() {
    let anyWorking = sessions.values.contains { $0.state == .working }
    if anyWorking, staleTimer == nil {
      let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.checkStale() }
      t.tolerance = 10
      RunLoop.main.add(t, forMode: .common)
      staleTimer = t
    } else if !anyWorking {
      staleTimer?.invalidate()
      staleTimer = nil
    }
  }

  private func checkStale() {
    var any = false
    for s in sessions.values where s.state == .working {
      let written = (try? FileManager.default.attributesOfItem(atPath: s.transcript)[.modificationDate] as? Date)
        ?? s.lastEvent
      let last = max(written, s.lastEvent)
      // A long tool (build, test run) writes nothing for a while; allow more time.
      if Date().timeIntervalSince(last) > (s.tool == nil ? 120 : 900) {
        set(s, .done)
        s.tool = nil
        any = true
      }
    }
    if any { changed() }
  }

  // MARK: - Rex

  static let rexPath: String? = [
    NSHomeDirectory() + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
    "/opt/homebrew/bin/rex", "/usr/local/bin/rex",
  ].first { FileManager.default.isExecutableFile(atPath: $0) }

  private static func rex(_ args: [String], output: ((Data) -> Void)? = nil) {
    guard let path = rexPath else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: path)
      p.arguments = args
      let pipe = Pipe()
      p.standardOutput = pipe
      p.standardError = pipe // errors (e.g. Remote Control off) come back through `output`
      guard (try? p.run()) != nil else { return }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      output?(data)
    }
  }

  /// The connected Rex app client most recently connected, or nil if none.
  private static func liveRexApp() -> String? {
    guard let path = rexPath else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = ["client", "ls", "--json"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let clients = root["clients"] as? [[String: Any]] else { return nil }
    return clients
      .filter { ($0["info"] as? [String: Any])?["kind"] as? String == "app" && $0["connection_state"] as? String != "lost" }
      .max { ($0["connected_at"] as? String ?? "") < ($1["connected_at"] as? String ?? "") }?["client_id"] as? String
  }

  /// The Rex session's label ("fix-login-redirect") reads better than a folder name.
  private func resolveLabel(_ s: Session) {
    let id = s.rexSession
    Self.rex(["ls", "--json"]) { data in
      guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["sessions"] as? [[String: Any]],
            let label = list.first(where: { $0["session_id"] as? String == id })?["label"] as? String
      else { return }
      DispatchQueue.main.async { [weak self] in
        s.rexLabel = label
        self?.onChange?()
      }
    }
  }

  /// Bring the session's terminal pane to the front.
  /// Why the last jump couldn't switch Rex sessions, shown in the panel; nil when it worked.
  private(set) var jumpProblem: String?

  /// Bring the session's terminal pane to the front: its Rex session, the tab it's in, the pane.
  func jump(to s: Session) {
    let rexApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.superlogical.rex").first
    rexApp?.activate()
    guard !s.rexSession.isEmpty else { return }
    let session = s.rexSession, block = s.rexBlock
    if s.state == .attention { markUnread(s, false) }
    Self.rex(["block", "inspect", "-s", session, block, "--json"]) { data in
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      let window = (root?["block"] as? [String: Any])?["window_id"] as? String
      // A restarted Rex can leave a disconnected app client behind, which makes the
      // default target ambiguous; address the live one explicitly.
      var select = Self.liveRexApp().map { ["-C", $0] } ?? []
      select += ["do", "session.select", "session_id=\(session)"]
      if let window { select.append("window_id=\(window)") }
      // Changing what the Rex app shows needs its Remote Control setting.
      Self.rex(select) { out in
        let text = String(decoding: out, as: UTF8.self)
        let problem = text.contains("Remote Control")
          ? "Rex can't switch sessions: turn on Remote Control in Rex → Settings → General."
          : nil
        DispatchQueue.main.async { [weak self] in
          guard let self, jumpProblem != problem else { return }
          jumpProblem = problem
          onChange?()
        }
        Self.rex(["focus", "-s", session, block])
      }
    }
  }

  // MARK: - Hooks

  static let settingsURL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
  private static let marker = "osx-utils/agents.sock"
  private static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                               "Notification", "Stop"]
  /// Sends in the background and returns at once, so a missing app costs Claude Code nothing.
  private static let command = #"/bin/sh -c 'p=$(cat); s="$HOME/.config/osx-utils/agents.sock"; [ -S "$s" ] || exit 0; (printf "%s\t%s\n%s" "$REX_SESSION" "$REX_BLOCK" "$p" | /usr/bin/nc -U -w 2 "$s" >/dev/null 2>&1 &); exit 0'"#

  static var hooksInstalled: Bool {
    guard let data = try? Data(contentsOf: settingsURL) else { return false }
    return String(decoding: data, as: UTF8.self).contains(marker)
  }

  /// Adds our hook to each event in ~/.claude/settings.json, keeping everything else.
  /// A copy of the original is saved next to it first.
  static func installHooks() throws {
    try editSettings { hooks in
      for e in events {
        var list = hooks[e] as? [[String: Any]] ?? []
        list.removeAll { isOurs($0) }
        var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
        if e == "PreToolUse" || e == "PostToolUse" { entry["matcher"] = "*" }
        list.append(entry)
        hooks[e] = list
      }
    }
  }

  static func removeHooks() throws {
    try editSettings { hooks in
      for (e, v) in hooks {
        guard var list = v as? [[String: Any]] else { continue }
        list.removeAll { isOurs($0) }
        hooks[e] = list.isEmpty ? nil : list
      }
    }
  }

  private static func isOurs(_ entry: [String: Any]) -> Bool {
    (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
  }

  private static func editSettings(_ edit: (inout [String: Any]) -> Void) throws {
    let fm = FileManager.default
    var root: [String: Any] = [:]
    if let data = try? Data(contentsOf: settingsURL) {
      guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
      }
      root = obj
      let backup = settingsURL.appendingPathExtension("before-nanov-osx-utils")
      if !fm.fileExists(atPath: backup.path) { try data.write(to: backup) }
    } else {
      try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    edit(&hooks)
    root["hooks"] = hooks.isEmpty ? nil : hooks
    let out = try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try out.write(to: settingsURL, options: .atomic)
  }
}
