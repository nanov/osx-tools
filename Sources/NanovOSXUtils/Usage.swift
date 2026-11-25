import Foundation

/// What Claude Code usage would have cost at API prices, read from the transcripts in
/// ~/.claude/projects.
///
/// Every assistant line carries the token counts of one API response. They are summed into
/// buckets of (UTC hour, model, project), and only the bytes added since the last read are
/// read again: per file we remember its size, mtime and how far we got. Buckets and file
/// offsets are saved to ~/Library/Caches, so a relaunch reads nothing old.
///
/// All state lives on one utility-QoS queue. Nothing runs unless the dashboard is opened
/// or a Claude Code hook names a transcript that changed.
final class Usage {
  enum Period: Int { case today, week, month }

  struct Totals {
    var cost = 0.0
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var tokens: Int64 { input + output + cacheRead + cacheWrite }

    mutating func add(_ o: Totals) {
      cost += o.cost
      input += o.input
      output += o.output
      cacheRead += o.cacheRead
      cacheWrite += o.cacheWrite
    }
  }

  struct Summary {
    var period = Period.today
    var totals = Totals()
    /// Cost share of each model, largest first.
    var modelShares: [Double] = []
    /// Hourly (today) or daily bars.
    var trend: [Double] = []
    var trendLabels: [String] = []
    var models: [(name: String, cost: Double)] = []
    var projects: [(name: String, cost: Double)] = []
    /// Cost per day for the activity grid, from `gridStart` (a week start) to today.
    var days: [Double] = []
    var gridStart = Date()
    var gridTotal = 0.0
    var activeDays = 0
    var busiest: (day: Date, cost: Double)?
    var streak = 0
    /// The current five-hour usage block, if one is open.
    var block: (start: Date, end: Date, cost: Double)?
    var unknownModels: [String] = []
  }

  /// Non-nil while the first full read runs: bytes read / bytes to read.
  private(set) var progress: Double?
  /// Main thread; called when new data has been read or the first read advanced.
  var onChange: (() -> Void)?

  private let q = DispatchQueue(label: "dev.nanov.osx-utils.usage", qos: .utility)
  private let root = NSHomeDirectory() + "/.claude/projects/"
  private static let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("dev.nanov.osx-utils/usage.bin")
  /// Every message counted in the kept window, so a copy in another transcript (resumed,
  /// forked or subagent sessions repeat earlier messages) isn't counted again. Sorted 64-bit
  /// entries: the top 44 bits hash message id + request id, the low 20 are the message's hour
  /// (hours since 1970, for pruning). Read through a memory map, so it costs clean,
  /// file-backed pages rather than footprint.
  private static let seenURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("dev.nanov.osx-utils/seen.bin")
  /// Days of history kept; the activity grid shows 13 weeks.
  private static let keepDays = 98

  // State below is touched only on `q`.
  private var loaded = false
  private var files: [String: FileState] = [:]
  private var buckets: [UInt64: Totals] = [:]
  private var models: [String] = []
  private var modelIndex: [String: Int] = [:]
  private var modelPrice: [Int] = [] // index into `prices`, -1 when unknown
  private var projects: [String] = []
  private var projectIndex: [String: Int] = [:]
  private var pending = Set<String>()
  private var pendingWork: DispatchWorkItem?
  private var saveWork: DispatchWorkItem?
  private var progressPosted = Date.distantPast
  /// Seen entries on disk (mapped) and those added since the last merge, by hash.
  private var seenMap: Data?
  private var fresh: [UInt64: UInt32] = [:]

  struct FileState {
    var size: Int64
    var mtime: Int64
    var offset: Int64
    /// Hashes of the last few message ids, so a reply split over lines that straddle two
    /// reads is still counted once.
    var recent: [UInt64]
  }

  // MARK: - Public (main thread)

  /// Dashboard opened: load the cache if needed, then read whatever changed.
  func refresh() {
    q.async { [self] in
      if !loaded { load() }
      sweep()
    }
  }

  /// A hook reported activity in this transcript. Read it (and its subagents) a little later,
  /// once the burst of events has passed. Ignored until the dashboard has been opened once.
  func noteTranscript(_ path: String) {
    guard path.hasPrefix(root) else { return }
    q.async { [self] in
      guard loaded else { return }
      pending.insert(path)
      pendingWork?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.readPending() }
      pendingWork = work
      q.asyncAfter(deadline: .now() + 3, execute: work)
    }
  }

  func summary(_ period: Period, done: @escaping (Summary) -> Void) {
    q.async { [self] in
      let s = makeSummary(period, now: Date())
      DispatchQueue.main.async { done(s) }
    }
  }

  // MARK: - Reading

  private func readPending() {
    let paths = pending
    pending.removeAll()
    var changed = false
    for path in paths {
      let rel = String(path.dropFirst(root.count))
      changed = readIfChanged(rel) || changed
      // Subagents of this session write next to it: <session>/subagents/*.jsonl
      let dir = (path as NSString).deletingPathExtension + "/subagents"
      for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".jsonl") {
        changed = readIfChanged(String(dir.dropFirst(root.count)) + "/" + name) || changed
      }
    }
    if changed { finishBatch() }
  }

  private func readIfChanged(_ rel: String) -> Bool {
    var st = stat()
    guard stat(root + rel, &st) == 0 else { return false }
    let size = Int64(st.st_size), mtime = Self.nanos(st.st_mtimespec)
    if let f = files[rel], f.size == size, f.mtime == mtime { return false }
    let reader = Reader(toRead: size - (files[rel]?.offset ?? 0))
    defer { reader.free() }
    read(rel, size: size, mtime: mtime, reader: reader)
    return true
  }

  /// Walk the projects folder and read every file whose size or mtime moved.
  private func sweep() {
    let started = Date()
    var found: [(String, Int64, Int64)] = []
    var total: Int64 = 0
    let cutoff = Int64(Date().addingTimeInterval(-Double(Self.keepDays) * 86400).timeIntervalSince1970) * 1_000_000_000
    var seen = Set<String>()
    Self.walk(root) { rel, size, mtime in
      seen.insert(rel)
      if let f = files[rel], f.size == size, f.mtime == mtime { return }
      if mtime < cutoff, files[rel] == nil {
        // Untouched for longer than we keep: note it so it's never read.
        files[rel] = FileState(size: size, mtime: mtime, offset: size, recent: [])
        return
      }
      found.append((rel, size, mtime))
      total += max(0, size - (files[rel]?.offset ?? 0))
    }
    let gone = files.keys.filter { !seen.contains($0) }
    gone.forEach { files[$0] = nil }
    guard !found.isEmpty else {
      if !gone.isEmpty { scheduleSave() }
      return
    }
    // A long first read reports progress; a few changed files don't.
    let showProgress = total > 64 << 20
    var done: Int64 = 0
    if showProgress { post(progress: 0) }
    let reader = Reader(toRead: found.map { $0.1 - (files[$0.0]?.offset ?? 0) }.max() ?? 0)
    defer { reader.free() }
    for (rel, size, mtime) in found {
      autoreleasepool {
        done += read(rel, size: size, mtime: mtime, reader: reader)
      }
      if showProgress { post(progress: Double(done) / Double(max(total, 1))) }
    }
    if showProgress {
      NSLog("usage: read %d files, %lld MB in %.2f s", found.count, total >> 20, Date().timeIntervalSince(started))
      post(progress: nil)
    }
    finishBatch(saveNow: showProgress) // a long read is worth keeping at once
  }

  private func post(progress p: Double?) {
    // At most a few updates a second reach the UI.
    if p != nil, p != 0, Date().timeIntervalSince(progressPosted) < 0.25 { return }
    progressPosted = Date()
    DispatchQueue.main.async { [weak self] in
      self?.progress = p
      self?.onChange?()
    }
  }

  private func finishBatch(saveNow: Bool = false) {
    prune()
    if saveNow { save() } else { scheduleSave() }
    DispatchQueue.main.async { [weak self] in self?.onChange?() }
  }

  /// Reads `rel` from its saved offset to the last complete line. Returns bytes read.
  @discardableResult
  private func read(_ rel: String, size: Int64, mtime: Int64, reader: Reader) -> Int64 {
    var state = files[rel] ?? FileState(size: 0, mtime: 0, offset: 0, recent: [])
    // Transcripts only grow. A file that shrank was replaced; skip what's there rather than
    // count it twice.
    if size < state.offset { state.offset = size }
    let fd = open(root + rel, O_RDONLY)
    guard fd >= 0 else { return 0 }
    defer { close(fd) }
    _ = fcntl(fd, F_NOCACHE, 1) // one pass over gigabytes shouldn't evict the user's file cache
    let start = state.offset
    var ctx = LineContext(usage: self, recent: state.recent)
    state.offset = reader.lines(fd: fd, from: start) { ctx.handle($0) }
    state.recent = ctx.recent
    state.size = size
    state.mtime = mtime
    files[rel] = state
    return state.offset - start
  }

  // MARK: - Lines

  /// Per-file parsing state: the last model and folder seen, so most lines reuse them.
  private struct LineContext {
    unowned let usage: Usage
    var recent: [UInt64]
    var lastModel: [UInt8] = []
    var lastModelIndex = 0
    var lastCwd: [UInt8] = []
    var lastProject = 0

    init(usage: Usage, recent: [UInt64]) {
      self.usage = usage
      self.recent = recent
    }

    /// Key order differs between Claude Code versions (`type` and `timestamp` come first in
    /// some lines, last in others), so top-level fields are taken from the end of the line,
    /// where tool inputs inside the message can't shadow them.
    mutating func handle(_ line: UnsafeRawBufferPointer) {
      guard let u = Scan.find(line, Scan.usage, from: 0) else { return }
      let tail = UnsafeRawBufferPointer(rebasing: line[u...])
      guard Scan.isAssistant(line),
            let model = Scan.string(line, after: Scan.model, from: 0, to: line.count),
            let ts = Scan.rstring(line, after: Scan.timestamp),
            let time = Scan.epoch(ts)
      else { return }
      if model.count == 11, Scan.equal(model, Scan.synthetic) { return }

      // One API response can be written as several lines; count it once.
      let id = Scan.string(line, after: Scan.messageID, from: 0, to: line.count)
      let req = Scan.rstring(line, after: Scan.requestID)
      if id != nil || req != nil {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        if let id { Scan.fnv(&h, id) }
        h = (h ^ 0x7C) &* 0x100_0000_01b3
        if let req { Scan.fnv(&h, req) }
        if recent.contains(h) { return }
        recent.append(h)
        if recent.count > 8 { recent.removeFirst() }
        if usage.seenBefore(h, hour: UInt32(max(0, time / 3600))) { return }
      }

      let window = UnsafeRawBufferPointer(rebasing: tail[..<min(tail.count, 4096)])
      var t = Totals()
      t.input = Scan.int(window, after: Scan.input)
      t.output = Scan.int(window, after: Scan.output)
      t.cacheRead = Scan.int(window, after: Scan.cacheRead)
      t.cacheWrite = Scan.int(window, after: Scan.cacheWrite)
      var w5 = t.cacheWrite, w1: Int64 = 0
      if Scan.find(window, Scan.ephemeral5m, from: 0) != nil || Scan.find(window, Scan.ephemeral1h, from: 0) != nil {
        w5 = Scan.int(window, after: Scan.ephemeral5m)
        w1 = Scan.int(window, after: Scan.ephemeral1h)
      }

      if !Scan.equal(model, lastModel) || lastModel.isEmpty {
        lastModel = Array(model)
        lastModelIndex = usage.internModel(String(decoding: model, as: UTF8.self))
      }
      let cwd = Scan.rstring(line, after: Scan.cwd) ?? UnsafeRawBufferPointer(start: nil, count: 0)
      if !Scan.equal(cwd, lastCwd) || lastCwd.isEmpty {
        lastCwd = Array(cwd)
        let name = (String(decoding: cwd, as: UTF8.self) as NSString).lastPathComponent
        lastProject = usage.internProject(name.isEmpty ? "–" : name)
      }
      let p = usage.modelPrice[lastModelIndex]
      var price = Usage.prices[p < 0 ? 0 : p]
      if let long = price.longContext, t.input + t.cacheRead + t.cacheWrite > 100_000 { price = long }
      t.cost = (Double(t.input) * price.input + Double(t.output) * price.output + Double(w5) * price.write5m
        + Double(w1) * price.write1h + Double(t.cacheRead) * price.cacheRead) / 1_000_000

      let hour = UInt64(max(0, time / 3600))
      let key = hour << 32 | UInt64(lastModelIndex) << 20 | UInt64(lastProject)
      usage.buckets[key, default: Totals()].add(t)
    }
  }

  // MARK: - Seen messages

  private static let hourMask: UInt64 = (1 << 20) - 1

  /// True when a message with this hash was already counted; otherwise remembers it.
  fileprivate func seenBefore(_ hash: UInt64, hour: UInt32) -> Bool {
    // FNV's high bits mix poorly; spread them before keeping only those.
    var z = hash &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    let key = (z ^ (z >> 31)) & ~Self.hourMask
    if fresh[key] != nil { return true }
    if let map = seenMap, Self.mapped(map, contains: key) { return true }
    fresh[key] = hour
    if fresh.count >= 1 << 16 { mergeSeen() } // keeps a first read from holding a million keys
    return false
  }

  /// Binary search for an entry whose hash bits equal `key`.
  private static func mapped(_ map: Data, contains key: UInt64) -> Bool {
    map.withUnsafeBytes { raw in
      let a = raw.bindMemory(to: UInt64.self)
      var lo = 0, hi = a.count
      while lo < hi {
        let mid = (lo + hi) / 2
        if a[mid] & ~hourMask < key { lo = mid + 1 } else { hi = mid }
      }
      return lo < a.count && a[lo] & ~hourMask == key
    }
  }

  /// Merges the new entries into the sorted file, dropping those older than the kept window,
  /// and maps the result. Streams through a small buffer, so it allocates little.
  private func mergeSeen() {
    guard !fresh.isEmpty else { return }
    let oldest = UInt64(max(0, (Int(Date().timeIntervalSince1970) - Self.keepDays * 86400) / 3600))
    var adds = fresh.map { $0.key | UInt64($0.value) & Self.hourMask }
    adds.sort()
    let tmp = Self.seenURL.path + ".tmp"
    try? FileManager.default.createDirectory(at: Self.seenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    var out = [UInt64]()
    out.reserveCapacity(8192)
    var ok = true
    func put(_ v: UInt64) {
      guard v & Self.hourMask >= oldest else { return }
      out.append(v)
      if out.count == 8192 { flush() }
    }
    func flush() {
      let n = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      if n != out.count * 8 { ok = false }
      out.removeAll(keepingCapacity: true)
    }
    let old = seenMap ?? Data()
    old.withUnsafeBytes { raw in
      let a = raw.bindMemory(to: UInt64.self)
      var i = 0, j = 0
      while i < a.count || j < adds.count {
        if j == adds.count || (i < a.count && a[i] < adds[j]) { put(a[i]); i += 1 } else { put(adds[j]); j += 1 }
      }
    }
    flush()
    close(fd)
    guard ok, rename(tmp, Self.seenURL.path) == 0 else { unlink(tmp); return }
    fresh = [:]
    seenMap = try? Data(contentsOf: Self.seenURL, options: .alwaysMapped)
  }

  fileprivate func internModel(_ id: String) -> Int {
    if let i = modelIndex[id] { return i }
    models.append(id)
    modelIndex[id] = models.count - 1
    modelPrice.append(Self.prices.firstIndex { id.hasPrefix($0.prefix) } ?? -1)
    return models.count - 1
  }

  fileprivate func internProject(_ name: String) -> Int {
    if let i = projectIndex[name] { return i }
    projects.append(name)
    projectIndex[name] = projects.count - 1
    return projects.count - 1
  }

  private func prune() {
    let oldest = UInt64(max(0, (Int(Date().timeIntervalSince1970) - Self.keepDays * 86400) / 3600))
    if buckets.keys.contains(where: { $0 >> 32 < oldest }) {
      buckets = buckets.filter { $0.key >> 32 >= oldest }
    }
  }

  // MARK: - Prices (USD per million tokens)

  final class Price {
    let prefix: String
    let name: String
    let input, output, write5m, write1h, cacheRead: Double
    /// Rates for prompts over 100K input tokens, where they differ.
    let longContext: Price?

    init(prefix: String, name: String, input: Double, output: Double, write5m: Double, write1h: Double,
         cacheRead: Double, longContext: Price? = nil) {
      self.prefix = prefix
      self.name = name
      self.input = input
      self.output = output
      self.write5m = write5m
      self.write1h = write1h
      self.cacheRead = cacheRead
      self.longContext = longContext
    }
  }

  /// First matching prefix wins, so specific versions come before their family. Unknown
  /// models are priced as the first entry and listed in `Summary.unknownModels`.
  static let prices: [Price] = [
    Price(prefix: "claude-opus-5-5", name: "Opus 5.5", input: 4, output: 20, write5m: 5, write1h: 8, cacheRead: 0.20),
    Price(prefix: "claude-fable-5-2", name: "Fable 5.2", input: 8, output: 40, write5m: 10, write1h: 16, cacheRead: 0.20),
    Price(prefix: "claude-fable-5-1", name: "Fable 5.1", input: 10, output: 50, write5m: 12.5, write1h: 20, cacheRead: 0.25),
    Price(prefix: "claude-fable-5", name: "Fable 5", input: 10, output: 50, write5m: 12.5, write1h: 20, cacheRead: 1.0),
    Price(prefix: "claude-opus-5", name: "Opus 5", input: 5, output: 25, write5m: 6.25, write1h: 10, cacheRead: 0.50),
    Price(prefix: "claude-opus-4-8", name: "Opus 4.8", input: 5, output: 25, write5m: 6.25, write1h: 10, cacheRead: 0.50),
    Price(prefix: "claude-opus-4-7", name: "Opus 4.7", input: 5, output: 25, write5m: 6.25, write1h: 10, cacheRead: 0.50),
    Price(prefix: "claude-opus-4-6", name: "Opus 4.6", input: 5, output: 25, write5m: 6.25, write1h: 10, cacheRead: 0.50),
    Price(prefix: "claude-opus-4-5", name: "Opus 4.5", input: 5, output: 25, write5m: 6.25, write1h: 10, cacheRead: 0.50),
    Price(prefix: "claude-sonnet-5-5", name: "Sonnet 5.5", input: 2, output: 10, write5m: 2.5, write1h: 4, cacheRead: 0.10),
    Price(prefix: "claude-sonnet-5", name: "Sonnet 5", input: 2, output: 10, write5m: 2.5, write1h: 4, cacheRead: 0.20),
    Price(prefix: "claude-sonnet-4-6", name: "Sonnet 4.6", input: 3, output: 15, write5m: 3.75, write1h: 6, cacheRead: 0.30),
    Price(prefix: "claude-sonnet-4-5", name: "Sonnet 4.5", input: 3, output: 15, write5m: 3.75, write1h: 6, cacheRead: 0.30),
    Price(prefix: "claude-sonnet-4", name: "Sonnet 4", input: 3, output: 15, write5m: 3.75, write1h: 6, cacheRead: 0.30),
    Price(prefix: "claude-haiku-5-5", name: "Haiku 5.5", input: 0.10, output: 0.50, write5m: 0.125, write1h: 0.20,
          cacheRead: 0.01,
          longContext: Price(prefix: "", name: "", input: 0.50, output: 2.50, write5m: 0.625, write1h: 1.0, cacheRead: 0.05)),
    Price(prefix: "claude-haiku-4-5", name: "Haiku 4.5", input: 1, output: 5, write5m: 1.25, write1h: 2, cacheRead: 0.10),
  ]

  /// "claude-opus-5-5-20261001" → "Opus 5.5" for models missing from the table.
  static func displayName(_ id: String) -> String {
    if let p = prices.first(where: { id.hasPrefix($0.prefix) }) { return p.name }
    var parts = id.split(separator: "-").map(String.init)
    if parts.first == "claude" { parts.removeFirst() }
    let words = parts.filter { Int($0) == nil }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    let version = parts.filter { Int($0) != nil && $0.count <= 2 }.joined(separator: ".")
    return (words.joined(separator: " ") + " " + version).trimmingCharacters(in: .whitespaces)
  }

  // MARK: - Summary

  private func makeSummary(_ period: Period, now: Date) -> Summary {
    var s = Summary()
    s.period = period
    let cal = Calendar.current
    let today = cal.startOfDay(for: now)

    // Activity grid: 13 columns of weeks, the last one holding today.
    let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
    let gridStart = cal.date(byAdding: .day, value: -84, to: weekStart) ?? weekStart
    var dayStarts: [Double] = [] // local midnights from gridStart to today, plus tomorrow
    var d = gridStart
    while d <= today {
      dayStarts.append(d.timeIntervalSince1970)
      d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
    }
    dayStarts.append(d.timeIntervalSince1970)
    let dayCount = dayStarts.count - 1
    s.gridStart = gridStart
    s.days = Array(repeating: 0, count: dayCount)

    let periodDays = period == .today ? 1 : period == .week ? 7 : 30
    let periodStart = (cal.date(byAdding: .day, value: 1 - periodDays, to: today) ?? today).timeIntervalSince1970
    s.trend = Array(repeating: 0, count: period == .today ? 24 : periodDays)
    var byModel: [Int: Double] = [:]
    var byProject: [Int: Double] = [:]
    var activeHours: [UInt64: Double] = [:]
    let todayStart = today.timeIntervalSince1970
    let firstDayIndexOfPeriod = dayCount - periodDays

    for (key, t) in buckets {
      let hour = key >> 32
      let at = Double(hour) * 3600
      activeHours[hour, default: 0] += t.cost
      guard at >= dayStarts[0] else { continue }
      let day = Self.dayIndex(at, dayStarts)
      if day >= 0 && day < dayCount { s.days[day] += t.cost }
      guard at >= periodStart else { continue }
      s.totals.add(t)
      byModel[Int(key >> 20 & 0xFFF), default: 0] += t.cost
      byProject[Int(key & 0xFFFFF), default: 0] += t.cost
      if period == .today {
        s.trend[min(23, max(0, Int((at - todayStart) / 3600)))] += t.cost
      } else if day - firstDayIndexOfPeriod >= 0 && day - firstDayIndexOfPeriod < periodDays {
        s.trend[day - firstDayIndexOfPeriod] += t.cost
      }
    }

    // Models merge by display name: dated snapshots of one model are one row.
    var named: [String: Double] = [:]
    for (i, c) in byModel { named[Self.displayName(models[i]), default: 0] += c }
    s.models = named.map { ($0.key, $0.value) }.sorted { $0.cost > $1.cost }
    let total = max(s.totals.cost, 0.000_001)
    s.modelShares = s.models.map { $0.cost / total }
    s.models = Array(s.models.prefix(3))
    s.projects = Array(byProject.map { (projects[$0.key], $0.value) }.sorted { $0.cost > $1.cost }.prefix(3))
    s.unknownModels = byModel.keys.filter { modelPrice[$0] < 0 }.map { models[$0] }

    if period == .today {
      s.trendLabels = ["00", "12", "23"]
    } else {
      let first = Date(timeIntervalSince1970: dayStarts[max(0, firstDayIndexOfPeriod)])
      s.trendLabels = [Format.day(first), "", Format.day(today)]
    }

    // Activity numbers.
    s.gridTotal = s.days.reduce(0, +)
    s.activeDays = s.days.filter { $0 > 0.005 }.count
    if let i = s.days.indices.max(by: { s.days[$0] < s.days[$1] }), s.days[i] > 0 {
      s.busiest = (Date(timeIntervalSince1970: dayStarts[i]), s.days[i])
    }
    // Streak of active days up to today; today may still be empty without breaking it.
    var i = dayCount - 1
    if i >= 0 && s.days[i] <= 0.005 { i -= 1 }
    while i >= 0 && s.days[i] > 0.005 {
      s.streak += 1
      i -= 1
    }

    // Five-hour blocks: a block starts at the hour of the first message after the previous
    // block ended and lasts five hours.
    var blockStart: UInt64?
    for h in activeHours.keys.sorted() where blockStart == nil || h >= blockStart! + 5 { blockStart = h }
    if let b = blockStart, Double(b + 5) * 3600 > now.timeIntervalSince1970 {
      let cost = (b..<b + 5).reduce(0) { $0 + (activeHours[$1] ?? 0) }
      s.block = (Date(timeIntervalSince1970: Double(b) * 3600), Date(timeIntervalSince1970: Double(b + 5) * 3600), cost)
    }
    return s
  }

  private static func dayIndex(_ t: Double, _ starts: [Double]) -> Int {
    var lo = 0, hi = starts.count - 1
    while lo < hi { // last start <= t
      let mid = (lo + hi + 1) / 2
      if starts[mid] <= t { lo = mid } else { hi = mid - 1 }
    }
    return lo
  }

  // MARK: - Cache file

  private static let magic: UInt64 = 0x4E_55_53_47_00_00_00_03 // "NUSG" v3: messages deduped across files

  private func scheduleSave() {
    saveWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.save() }
    saveWork = work
    q.asyncAfter(deadline: .now() + 5, execute: work)
  }

  private func save() {
    mergeSeen() // before the offsets that say these messages were read
    var w = ByteWriter()
    w.u64(Self.magic)
    w.u64(UInt64(models.count))
    models.forEach { w.str($0) }
    w.u64(UInt64(projects.count))
    projects.forEach { w.str($0) }
    w.u64(UInt64(files.count))
    for (rel, f) in files {
      w.str(rel)
      w.i64(f.size); w.i64(f.mtime); w.i64(f.offset)
      w.u64(UInt64(f.recent.count))
      f.recent.forEach { w.u64($0) }
    }
    w.u64(UInt64(buckets.count))
    for (k, t) in buckets {
      w.u64(k); w.f64(t.cost); w.i64(t.input); w.i64(t.output); w.i64(t.cacheRead); w.i64(t.cacheWrite)
    }
    try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? w.data.write(to: Self.cacheURL, options: .atomic)
  }

  private func load() {
    loaded = true
    // The seen set belongs to the totals in usage.bin; without them it starts over too.
    func startOver() { try? FileManager.default.removeItem(at: Self.seenURL) }
    guard let data = try? Data(contentsOf: Self.cacheURL) else { return startOver() }
    var r = ByteReader(data: data)
    guard r.u64() == Self.magic else { return startOver() }
    for _ in 0..<r.count() { _ = internModel(r.str()) }
    for _ in 0..<r.count() { _ = internProject(r.str()) }
    let n = r.count()
    files.reserveCapacity(n)
    for _ in 0..<n {
      let rel = r.str()
      var f = FileState(size: r.i64(), mtime: r.i64(), offset: r.i64(), recent: [])
      for _ in 0..<min(8, r.count()) { f.recent.append(r.u64()) }
      files[rel] = f
    }
    let b = r.count()
    buckets.reserveCapacity(b)
    for _ in 0..<b {
      let k = r.u64()
      buckets[k] = Totals(cost: r.f64(), input: r.i64(), output: r.i64(), cacheRead: r.i64(), cacheWrite: r.i64())
    }
    if r.failed { // damaged: start over
      files = [:]; buckets = [:]; models = []; modelIndex = [:]; modelPrice = []; projects = []; projectIndex = [:]
      return startOver()
    }
    seenMap = try? Data(contentsOf: Self.seenURL, options: .alwaysMapped)
  }

  // MARK: - Files

  private static func nanos(_ t: timespec) -> Int64 { Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec) }

  /// Every *.jsonl under `root`, as (path relative to root, size, mtime).
  private static func walk(_ root: String, _ visit: (String, Int64, Int64) -> Void) {
    root.withCString { cRoot in
      var paths: [UnsafeMutablePointer<CChar>?] = [strdup(cRoot), nil]
      defer { free(paths[0]) }
      guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
      defer { fts_close(fts) }
      let skip = strlen(cRoot)
      while let e = fts_read(fts) {
        let ent = e.pointee
        guard ent.fts_info == FTS_F, let st = ent.fts_statp else { continue }
        let len = Int(ent.fts_pathlen)
        guard len > skip + 6 else { continue }
        let path = ent.fts_path!
        guard memcmp(path + len - 6, ".jsonl", 6) == 0 else { continue }
        var rel = path + skip
        while rel.pointee == 0x2F { rel += 1 } // fts may join with a second slash
        let relPath = String(cString: rel)
        visit(relPath, Int64(st.pointee.st_size), nanos(st.pointee.st_mtimespec))
      }
    }
  }
}

// MARK: - Chunked line reader

/// Reads a file in chunks of up to 4 MB and hands over each complete line that holds a usage record.
/// Lines are found from the marker outwards, so the bytes of other lines are only searched,
/// never split. A line longer than the buffer is skipped unless it holds the marker, in
/// which case it is read again in one piece.
private final class Reader {
  private let capacity: Int
  private let buf: UnsafeMutableRawPointer

  /// Up to 4 MB, but no bigger than the reads ahead need.
  init(toRead bytes: Int64) {
    capacity = Int(min(4 << 20, max(64 << 10, bytes)))
    buf = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
  }

  func free() { buf.deallocate() }

  /// Returns the file offset just past the last complete line.
  func lines(fd: Int32, from start: Int64, _ handle: (UnsafeRawBufferPointer) -> Void) -> Int64 {
    let cap = capacity
    let markerLength = Scan.usage.count
    var fileOffset = start // offset of buf[0]
    var filled = 0
    var skipping = false // inside a line longer than the buffer
    var skipStart: Int64 = 0
    var skipHasMarker = false
    while true {
      let n = pread(fd, buf + filled, cap - filled, fileOffset + Int64(filled))
      if n <= 0 { break }
      filled += n
      var region = UnsafeRawBufferPointer(start: buf, count: filled)

      if skipping {
        guard let nl = memchr(buf, 0x0A, filled) else {
          if Scan.marker(region, from: 0) != nil { skipHasMarker = true }
          // Keep a few bytes so a marker split across reads is still seen.
          let keep = min(filled, markerLength)
          memmove(buf, buf + filled - keep, keep)
          fileOffset += Int64(filled - keep)
          filled = keep
          continue
        }
        let end = buf.distance(to: nl)
        if Scan.marker(UnsafeRawBufferPointer(rebasing: region[..<end]), from: 0) != nil { skipHasMarker = true }
        let lineEnd = fileOffset + Int64(end)
        if skipHasMarker { readLong(fd: fd, from: skipStart, to: lineEnd, handle) }
        skipping = false
        let consumed = end + 1
        memmove(buf, buf + consumed, filled - consumed)
        fileOffset += Int64(consumed)
        filled -= consumed
        region = UnsafeRawBufferPointer(start: buf, count: filled) // lines after it are handled below
      }

      var pos = 0
      var lastLineEnd = 0 // bytes fully handled
      while let hit = Scan.marker(region, from: pos) {
        guard let nl = memchr(buf + hit, 0x0A, filled - hit) else { break }
        let end = buf.distance(to: nl)
        var lineStart = lastLineEnd
        while let p = memchr(buf + lineStart, 0x0A, hit - lineStart) { lineStart = buf.distance(to: p) + 1 }
        handle(UnsafeRawBufferPointer(rebasing: region[lineStart..<end]))
        pos = end + 1
        lastLineEnd = pos
      }
      // Everything up to the last newline is done.
      var consumed = lastLineEnd
      if let lastNL = Self.lastNewline(buf, from: lastLineEnd, to: filled) { consumed = lastNL + 1 }
      if consumed == 0 && filled == cap {
        // One line fills the whole buffer.
        skipping = true
        skipStart = fileOffset
        skipHasMarker = Scan.marker(region, from: 0) != nil
        let keep = markerLength
        memmove(buf, buf + filled - keep, keep)
        fileOffset += Int64(filled - keep)
        filled = keep
        continue
      }
      memmove(buf, buf + consumed, filled - consumed)
      fileOffset += Int64(consumed)
      filled -= consumed
    }
    return skipping ? skipStart : fileOffset
  }

  private func readLong(fd: Int32, from: Int64, to: Int64, _ handle: (UnsafeRawBufferPointer) -> Void) {
    let len = Int(to - from)
    guard len > 0, len < 64 << 20 else { return }
    let p = UnsafeMutableRawPointer.allocate(byteCount: len, alignment: 16)
    defer { p.deallocate() }
    guard pread(fd, p, len, from) == len else { return }
    handle(UnsafeRawBufferPointer(start: p, count: len))
  }

  private static func lastNewline(_ p: UnsafeMutableRawPointer, from: Int, to: Int) -> Int? {
    var i = to - 1
    while i >= from {
      if p.load(fromByteOffset: i, as: UInt8.self) == 0x0A { return i }
      i -= 1
    }
    return nil
  }
}

// MARK: - Byte scanning

/// Field lookups on raw JSON lines. Inside a JSON string every quote is escaped, so a match
/// on `"key":` can only be a real key.
private enum Scan {
  static let usage = Array(#""usage":{"#.utf8)
  static let type = Array(#""type":""#.utf8)
  static let assistant = Array("assistant".utf8)
  static let model = Array(#""model":""#.utf8)
  static let messageID = Array(#""id":"msg_"#.utf8)
  static let requestID = Array(#""requestId":""#.utf8)
  static let timestamp = Array(#""timestamp":""#.utf8)
  static let cwd = Array(#""cwd":""#.utf8)
  static let input = Array(#""input_tokens":"#.utf8)
  static let output = Array(#""output_tokens":"#.utf8)
  static let cacheRead = Array(#""cache_read_input_tokens":"#.utf8)
  static let cacheWrite = Array(#""cache_creation_input_tokens":"#.utf8)
  static let ephemeral5m = Array(#""ephemeral_5m_input_tokens":"#.utf8)
  static let ephemeral1h = Array(#""ephemeral_1h_input_tokens":"#.utf8)
  static let synthetic = Array("<synthetic>".utf8)

  static func find(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8], from: Int) -> Int? {
    guard let base = hay.baseAddress, from < hay.count else { return nil }
    return needle.withUnsafeBytes { n -> Int? in
      guard let r = memmem(base + from, hay.count - from, n.baseAddress, n.count) else { return nil }
      return base.distance(to: UnsafeRawPointer(r))
    }
  }

  /// `find(hay, usage, from:)`, 16 bytes at a time: a candidate needs "u" at its second byte
  /// and "{" at its ninth, which almost no other position in a transcript has. Several
  /// times faster than memmem, which matters across gigabytes.
  static func marker(_ hay: UnsafeRawBufferPointer, from: Int) -> Int? {
    guard let base = hay.baseAddress else { return nil }
    let n = hay.count
    let u = SIMD16<UInt8>(repeating: 0x75), brace = SIMD16<UInt8>(repeating: 0x7B)
    var i = from
    while i + 24 <= n {
      let a = base.loadUnaligned(fromByteOffset: i + 1, as: SIMD16<UInt8>.self)
      let b = base.loadUnaligned(fromByteOffset: i + 8, as: SIMD16<UInt8>.self)
      let m = (a .== u) .& (b .== brace)
      if any(m) {
        for j in 0..<16 where m[j] && memcmp(base + i + j, usageBytes, 9) == 0 { return i + j }
      }
      i += 16
    }
    return i < n ? find(hay, usage, from: i) : nil
  }

  private static let usageBytes: UnsafeMutableRawPointer = {
    let p = UnsafeMutableRawPointer.allocate(byteCount: 9, alignment: 1)
    usage.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: 9) }
    return p
  }()

  static func rfind(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Int? {
    guard let base = hay.baseAddress, hay.count >= needle.count else { return nil }
    let first = needle[0]
    var i = hay.count - needle.count
    return needle.withUnsafeBytes { n -> Int? in
      while i >= 0 {
        if hay[i] == first && memcmp(base + i, n.baseAddress!, n.count) == 0 { return i }
        i -= 1
      }
      return nil
    }
  }

  /// The string value right after `key` (which ends with the opening quote).
  static func string(_ hay: UnsafeRawBufferPointer, after key: [UInt8], from: Int, to: Int) -> UnsafeRawBufferPointer? {
    let limited = UnsafeRawBufferPointer(rebasing: hay[..<to])
    guard let k = find(limited, key, from: from) else { return nil }
    // `"id":"msg_` includes the start of the value; keep it.
    let start = key.last == 0x22 ? k + key.count : k + 6
    return value(hay, start)
  }

  static func rstring(_ hay: UnsafeRawBufferPointer, after key: [UInt8]) -> UnsafeRawBufferPointer? {
    guard let k = rfind(hay, key) else { return nil }
    return value(hay, k + key.count)
  }

  private static func value(_ hay: UnsafeRawBufferPointer, _ start: Int) -> UnsafeRawBufferPointer? {
    var i = start
    while i < hay.count && hay[i] != 0x22 {
      if hay[i] == 0x5C { i += 1 } // escaped character
      i += 1
    }
    guard i <= hay.count else { return nil }
    return UnsafeRawBufferPointer(rebasing: hay[start..<min(i, hay.count)])
  }

  static func int(_ hay: UnsafeRawBufferPointer, after key: [UInt8]) -> Int64 {
    guard var i = find(hay, key, from: 0).map({ $0 + key.count }) else { return 0 }
    while i < hay.count && hay[i] == 0x20 { i += 1 }
    var v: Int64 = 0
    while i < hay.count, hay[i] >= 0x30, hay[i] <= 0x39 {
      v = v &* 10 &+ Int64(hay[i] - 0x30)
      i += 1
    }
    return v
  }

  /// The line's own `type` is either its first `type` key or its last one, depending on the
  /// Claude Code version; nested ones (message, content blocks) sit in between.
  static func isAssistant(_ line: UnsafeRawBufferPointer) -> Bool {
    if let v = string(line, after: type, from: 0, to: line.count), equal(v, assistant) { return true }
    if let v = rstring(line, after: type), equal(v, assistant) { return true }
    return false
  }

  static func equal(_ a: UnsafeRawBufferPointer, _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    return b.withUnsafeBytes { memcmp(a.baseAddress!, $0.baseAddress!, a.count) == 0 }
  }

  static func fnv(_ h: inout UInt64, _ bytes: UnsafeRawBufferPointer) {
    for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
  }

  /// "2026-11-23T12:31:14.676Z" → seconds since 1970 (UTC).
  static func epoch(_ s: UnsafeRawBufferPointer) -> Int? {
    guard s.count >= 19 else { return nil }
    func num(_ a: Int, _ n: Int) -> Int {
      var v = 0
      for i in a..<a + n { v = v * 10 + Int(s[i]) - 48 }
      return v
    }
    var y = num(0, 4), m = num(5, 2)
    let d = num(8, 2), hh = num(11, 2), mm = num(14, 2), ss = num(17, 2)
    // Days from civil (Howard Hinnant).
    y -= m <= 2 ? 1 : 0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    m = m > 2 ? m - 3 : m + 9
    let doy = (153 * m + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146_097 + doe - 719_468
    return days * 86400 + hh * 3600 + mm * 60 + ss
  }
}

// MARK: - Binary cache format

private struct ByteWriter {
  var data = Data()
  mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
  mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
  mutating func f64(_ v: Double) { u64(v.bitPattern) }
  mutating func str(_ s: String) {
    let b = Array(s.utf8)
    u64(UInt64(b.count))
    data.append(contentsOf: b)
  }
}

private struct ByteReader {
  let data: Data
  var pos = 0
  var failed = false

  mutating func u64() -> UInt64 {
    guard pos + 8 <= data.count else { failed = true; return 0 }
    var v: UInt64 = 0
    _ = withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: data.startIndex + pos..<data.startIndex + pos + 8) }
    pos += 8
    return UInt64(littleEndian: v)
  }
  mutating func i64() -> Int64 { Int64(bitPattern: u64()) }
  mutating func f64() -> Double { Double(bitPattern: u64()) }
  mutating func count() -> Int {
    let n = u64()
    if n > 10_000_000 { failed = true; return 0 }
    return Int(n)
  }
  mutating func str() -> String {
    let n = Int(u64())
    guard !failed, n >= 0, pos + n <= data.count else { failed = true; return "" }
    let s = String(decoding: data[data.startIndex + pos..<data.startIndex + pos + n], as: UTF8.self)
    pos += n
    return s
  }
}
