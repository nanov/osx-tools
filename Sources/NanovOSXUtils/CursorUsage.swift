import CommonCrypto
import Foundation
import Security
import SQLite3

/// Cursor's plan usage for the current billing period, from cursor.com's own dashboard API
/// (`GET /api/usage-summary`, the call cursor.com/dashboard makes). It is undocumented and may
/// change; any failure shows as "unavailable".
///
/// The request is signed in as Cursor is: its access token, read from Cursor's state database
/// (opened read-only), sealed with Electron safeStorage. The key to open it is the "Cursor Safe
/// Storage" item in the login keychain. Key and token live only for one check, are sent
/// nowhere but cursor.com, and are never written.
///
/// macOS asks before handing the key over, and only `connect()` lets it ask: the panel's
/// Install Hooks and Connect Usage buttons, where the user can choose Always Allow. The
/// dashboard's checks, made when it opens and the last reading is over a minute old, never
/// show a prompt; if one would be needed they stop until the next launch.
final class CursorUsage {
  struct Reading: Codable {
    var plan: String?
    /// The signed-in account, from Cursor's own state (`cursorAuth/cachedEmail`).
    var email: String?
    /// Included usage used, 0…100+.
    var percent: Double?
    /// Spent this period in US cents: included usage plus on-demand.
    var spentCents: Double?
    var onDemandCents: Double?
    var resets: Date?
    var at: Date
  }

  private(set) var reading: Reading?
  private(set) var failed = false
  private(set) var loading = false
  /// Cursor is installed and has a sign-in to read (or had one at the last check).
  private(set) var available = false
  var onChange: (() -> Void)?

  private var generation = 0
  /// A silent keychain read was refused during this run; only `connect()` tries again.
  private(set) static var denied = false
  /// Set once the user let this app read the key; cleared by Remove Hooks.
  static var connected: Bool {
    get { UserDefaults.standard.bool(forKey: "cursorUsage") }
    set { UserDefaults.standard.set(newValue, forKey: "cursorUsage") }
  }

  static let databasePath = NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

  private static var cacheURL: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dev.nanov.osx-utils/cursor.json")
  }

  init() {
    guard Agents.cursorInstalled, FileManager.default.fileExists(atPath: Self.databasePath) else { return }
    if let data = try? Data(contentsOf: Self.cacheURL) {
      let d = JSONDecoder()
      d.dateDecodingStrategy = .secondsSince1970
      reading = try? d.decode(Reading.self, from: data)
    }
    available = reading != nil
  }

  /// Starts a check unless one is running, the last reading is under a minute old, or Cursor
  /// isn't there.
  func refreshIfStale() {
    guard !loading, Agents.cursorInstalled, FileManager.default.fileExists(atPath: Self.databasePath) else { return }
    if let r = reading, !failed, Date().timeIntervalSince(r.at) < 60 { return }
    if Self.denied { failed = true; return }
    run(interactive: false)
  }

  /// Asks macOS for the key, with its prompt, then checks. Called from a button press.
  func connect(done: (() -> Void)? = nil) {
    Self.denied = false
    run(interactive: true, done: done)
  }

  private func run(interactive: Bool, done: (() -> Void)? = nil) {
    loading = true
    generation += 1
    let gen = generation
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let result = Self.check(interactive: interactive)
      DispatchQueue.main.async {
        guard let self, gen == self.generation else { return }
        self.loading = false
        switch result {
        case .reading(let r):
          self.reading = r
          self.failed = false
          self.available = true
          self.save(r)
        case .signedOut:
          self.available = false
          self.reading = nil
          try? FileManager.default.removeItem(at: Self.cacheURL)
        case .denied:
          Self.denied = true
          self.failed = true
          self.available = true
        case .failed:
          self.failed = true
        }
        self.onChange?()
        done?()
      }
    }
  }

  /// Drops a running check's result (the dashboard closed). A keychain prompt that's up stays
  /// up; its answer is still remembered.
  func cancel() {
    guard loading else { return }
    generation += 1
    loading = false
  }

  private func save(_ r: Reading) {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .secondsSince1970
    guard let data = try? e.encode(r) else { return }
    try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: Self.cacheURL, options: .atomic)
  }

  // MARK: - The check

  private enum Result {
    case reading(Reading), signedOut, denied, failed
  }

  /// One check, on a background thread.
  private static func check(interactive: Bool) -> Result {
    guard let stored = storedValue("cursorAuth/accessToken"), !stored.isEmpty else { return .signedOut }
    let token: String
    switch unseal(stored, interactive: interactive) {
    case .token(let t): token = t
    case .denied: return .denied
    case .failed: return .failed
    }
    guard let claims = jwtClaims(token), let sub = claims["sub"] as? String,
          let subject = sub.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return .failed }
    if let exp = claims["exp"] as? Double, exp < Date().timeIntervalSince1970 { return .signedOut }
    guard let json = get("https://cursor.com/api/usage-summary",
                         cookie: "WorkosCursorSessionToken=\(subject)%3A%3A\(token)") else { return .failed }
    guard var r = parse(json) else { return .failed }
    r.email = storedValue("cursorAuth/cachedEmail").flatMap { $0.isEmpty ? nil : $0 }
    return .reading(r)
  }

  /// The usage-summary reply: `membershipType`, `billingCycleEnd`, and per pool (`plan`,
  /// `onDemand`) `used` and `limit` in cents. The plan's `totalPercentUsed` is what cursor.com
  /// shows: it counts the Auto pool too, so it can sit far below used/limit.
  static func parse(_ root: [String: Any]) -> Reading? {
    func number(_ v: Any?) -> Double? {
      if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
      return (v as? String).flatMap(Double.init)
    }
    let individual = root["individualUsage"] as? [String: Any]
    var plan = individual?["plan"] as? [String: Any]
    // Team seats report the member's allowance as "overall".
    if plan == nil || plan?["enabled"] as? Bool == false, let overall = individual?["overall"] as? [String: Any] {
      plan = overall
    }
    let onDemand = (individual?["onDemand"] as? [String: Any]).flatMap { $0["enabled"] as? Bool == false ? nil : $0 }
    var r = Reading(at: Date())
    r.plan = (root["membershipType"] as? String).map(planName)
    if let p = plan, p["enabled"] as? Bool != false {
      r.percent = number(p["totalPercentUsed"])
      if r.percent == nil, let used = number(p["used"]), let limit = number(p["limit"]), limit > 0 {
        r.percent = used / limit * 100
      }
      r.spentCents = number(p["used"])
    }
    if let od = number(onDemand?["used"]) {
      r.onDemandCents = od
      r.spentCents = (r.spentCents ?? 0) + od
    }
    r.resets = date(root["billingCycleEnd"])
    guard r.percent != nil || r.spentCents != nil || r.plan != nil else { return nil }
    return r
  }

  private static func planName(_ raw: String) -> String {
    let known = ["free": "Hobby", "hobby": "Hobby", "pro": "Pro", "pro_plus": "Pro+", "pro plus": "Pro+",
                 "ultra": "Ultra", "business": "Teams", "team": "Teams", "enterprise": "Enterprise"]
    return known[raw.lowercased()] ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
  }

  private static let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private static func date(_ v: Any?) -> Date? {
    if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue > 1e12 ? n.doubleValue / 1000 : n.doubleValue) }
    guard let s = v as? String else { return nil }
    if let ms = Double(s) { return date(NSNumber(value: ms)) }
    return isoFractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
  }

  // MARK: Cursor's state database

  /// One value from the database's ItemTable, opened read-only.
  private static func storedValue(_ key: String) -> String? {
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    sqlite3_busy_timeout(db, 2000)
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1", -1, &stmt, nil) == SQLITE_OK
    else { return nil }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, 1, key, -1, transient)
    guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
    let n = Int(sqlite3_column_bytes(stmt, 0))
    return String(decoding: UnsafeRawBufferPointer(start: bytes, count: n), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: Electron safeStorage

  private enum Unsealed { case token(String), denied, failed }

  /// "cursor-safe-storage:v1:" + base64 of Electron `safeStorage.encryptString`, which on macOS
  /// is Chromium's OSCrypt: "v10", then AES-128-CBC with a 16-space IV, keyed by
  /// PBKDF2-HMAC-SHA1(keychain password, "saltysalt", 1003 rounds). A plain value is a token.
  private static func unseal(_ stored: String, interactive: Bool) -> Unsealed {
    let prefix = "cursor-safe-storage:v1:"
    guard stored.hasPrefix(prefix) else { return .token(stored) }
    guard let blob = Data(base64Encoded: String(stored.dropFirst(prefix.count))), blob.count > 3,
          blob.prefix(3) == Data("v10".utf8) else { return .failed }
    var status: OSStatus = 0
    guard var password = keychainPassword(interactive: interactive, &status) else {
      return status == errSecAuthFailed || status == errSecUserCanceled || status == errSecInteractionNotAllowed
        ? .denied : .failed
    }
    if interactive { DispatchQueue.main.async { connected = true } }
    defer { password.resetBytes(in: 0..<password.count) }
    var key = Data(count: kCCKeySizeAES128)
    defer { key.resetBytes(in: 0..<key.count) }
    let salt = Data("saltysalt".utf8)
    let derived = key.withUnsafeMutableBytes { k in
      password.withUnsafeBytes { p in
        salt.withUnsafeBytes { s in
          CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: CChar.self), p.count,
                               s.baseAddress?.assumingMemoryBound(to: UInt8.self), s.count,
                               CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                               k.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
        }
      }
    }
    guard derived == kCCSuccess else { return .failed }
    let cipher = blob.dropFirst(3)
    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    var plain = Data(count: cipher.count + kCCBlockSizeAES128)
    var plainCount = 0
    let status2 = plain.withUnsafeMutableBytes { out in
      cipher.withUnsafeBytes { c in
        key.withUnsafeBytes { k in
          iv.withUnsafeBytes { v in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, k.count, v.baseAddress, c.baseAddress, c.count,
                    out.baseAddress, out.count, &plainCount)
          }
        }
      }
    }
    defer { plain.resetBytes(in: 0..<plain.count) }
    guard status2 == kCCSuccess else { return .failed }
    let token = String(decoding: plain.prefix(plainCount), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? .failed : .token(token)
  }

  /// The "Cursor Safe Storage" password (account "Cursor Key", or "Cursor" before Cursor 3.27).
  /// Interactive, macOS may show its prompt and this blocks until the user answers; otherwise
  /// a read that would need the prompt fails with errSecInteractionNotAllowed.
  private static func keychainPassword(interactive: Bool, _ status: inout OSStatus) -> Data? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Cursor Safe Storage",
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
    ]
    // kSecUseAuthenticationUI: kSecUseAuthenticationUIFail, spelled out because the constants
    // are deprecated. LAContext.interactionNotAllowed, their replacement, only covers items
    // with access control, not the file keychain's per-app prompt this item has.
    if !interactive { query["u_AuthUI"] = "u_AuthUIF" }
    var out: CFTypeRef?
    status = SecItemCopyMatching(query as CFDictionary, &out)
    return status == errSecSuccess ? out as? Data : nil
  }

  private static func jwtClaims(_ jwt: String) -> [String: Any]? {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
    guard let data = Data(base64Encoded: b64) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  // MARK: HTTP

  /// No cookie jar, no cache, no redirects: the cookie goes to cursor.com and nowhere else.
  private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
      completionHandler(nil)
    }
  }

  private static func get(_ url: String, cookie: String) -> [String: Any]? {
    guard let u = URL(string: url), u.scheme == "https", u.host == "cursor.com" else { return nil }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.timeoutIntervalForRequest = 15
    let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    var req = URLRequest(url: u)
    req.setValue(cookie, forHTTPHeaderField: "Cookie")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
    req.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
    var result: [String: Any]?
    let done = DispatchSemaphore(value: 0)
    session.dataTask(with: req) { data, response, _ in
      defer { done.signal() }
      guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { return }
      result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }.resume()
    done.wait()
    return result
  }
}
