import Foundation
import CoreGraphics
import IOKit

// DDC/CI over the Apple Silicon display coprocessor's I2C channel.
// The IOAVService calls live in CoreDisplay and are private, so they're resolved at runtime.

private let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)

private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

private func sym<T>(_ name: String, _: T.Type) -> T? {
  guard let h = coreDisplay, let p = dlsym(h, name) else { return nil }
  return unsafeBitCast(p, to: T.self)
}

private let avCreate = sym("IOAVServiceCreateWithService", CreateFn.self)
private let avWrite = sym("IOAVServiceWriteI2C", I2CFn.self)
private let avRead = sym("IOAVServiceReadI2C", I2CFn.self)

enum VCP: UInt8 {
  case luminance = 0x10
}

/// One external monitor's DDC channel. All I/O blocks, so call it from a serial queue.
final class DDCPort {
  let service: CFTypeRef
  let edidUUID: String
  let location: String
  let productName: String?
  let serial: String?
  /// MCDP29xx DP→HDMI converters accept writes at 0x37 and silently drop them; they listen at 0xB7.
  let chip: UInt32
  private var lastCommand: UInt64 = 0

  private init(service: CFTypeRef, edidUUID: String, location: String, productName: String?, serial: String?, chip: UInt32) {
    self.service = service
    self.edidUUID = edidUUID
    self.location = location
    self.productName = productName
    self.serial = serial
    self.chip = chip
  }

  func set(_ code: VCP, _ value: UInt16) -> Bool {
    pace()
    let packet = Self.packet([0x03, code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)])
    for attempt in 0..<4 {
      if attempt > 0 { usleep(20_000) }
      var ok = true
      for _ in 0..<2 { // some monitors only act on the repeat
        usleep(10_000)
        ok = write(packet) && ok
      }
      if ok { return true }
    }
    return false
  }

  /// (current, max), or nil if the monitor didn't give a valid reply.
  func get(_ code: VCP) -> (UInt16, UInt16)? {
    pace()
    let packet = Self.packet([0x01, code.rawValue])
    for attempt in 0..<4 {
      if attempt > 0 { usleep(20_000) }
      usleep(10_000)
      guard write(packet) else { continue }
      usleep(50_000)
      var reply = [UInt8](repeating: 0, count: 11)
      guard let avRead, avRead(service, chip, 0, &reply, 11) == kIOReturnSuccess else { continue }
      let check = reply[0..<10].reduce(UInt8(0x50), ^)
      // reply[4] == code guards against monitors answering the previous request.
      guard check == reply[10], reply[2] == 0x02, reply[3] == 0, reply[4] == code.rawValue else { continue }
      let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
      let cur = UInt16(reply[8]) << 8 | UInt16(reply[9])
      return (cur, max == 0 ? 100 : max)
    }
    return nil
  }

  /// Some monitors drop their signal if commands arrive faster than ~50 ms apart.
  private func pace() {
    let now = DispatchTime.now().uptimeNanoseconds
    let gap: UInt64 = 50_000_000
    if now - lastCommand < gap { usleep(useconds_t((gap - (now - lastCommand)) / 1000)) }
    lastCommand = DispatchTime.now().uptimeNanoseconds
  }

  private func write(_ packet: [UInt8]) -> Bool {
    guard let avWrite else { return false }
    var buf = packet
    return avWrite(service, chip, 0x51, &buf, UInt32(buf.count)) == kIOReturnSuccess
  }

  /// [0x80 | len, opcode, payload…, checksum]; the checksum is seeded with the
  /// destination (0x6E) and source (0x51) addresses.
  private static func packet(_ body: [UInt8]) -> [UInt8] {
    var p = [UInt8(0x80 | body.count)] + body
    p.append(p.reduce(UInt8(0x6E ^ 0x51), ^))
    return p
  }

  // MARK: - Discovery

  /// Walk the IORegistry: each display framebuffer (AppleCLCD2 / IOMobileFramebufferShim)
  /// carries the EDID identity, and the DCPAVServiceProxy that follows it is its I2C channel.
  static func discover() -> [DDCPort] {
    guard let avCreate else { return [] }
    var iter: io_iterator_t = 0
    guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                   &iter) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iter) }

    var ports: [DDCPort] = []
    var pending: (uuid: String, path: String, name: String?, serial: String?)?
    while case let entry = IOIteratorNext(iter), entry != 0 {
      defer { IOObjectRelease(entry) }
      var nameBuf = [CChar](repeating: 0, count: 128)
      IORegistryEntryGetName(entry, &nameBuf)
      let name = String(cString: nameBuf)

      if name.contains("AppleCLCD2") || name.contains("IOMobileFramebufferShim") {
        let uuid = property(entry, "EDID UUID") as? String ?? ""
        var pathBuf = [CChar](repeating: 0, count: 512)
        IORegistryEntryGetPath(entry, kIOServicePlane, &pathBuf)
        let attrs = (property(entry, "DisplayAttributes") as? [String: Any])?["ProductAttributes"] as? [String: Any]
        pending = (uuid, String(cString: pathBuf), attrs?["ProductName"] as? String,
                   (attrs?["SerialNumber"]).map { "\($0)" })
      } else if name == "DCPAVServiceProxy", let p = pending,
                property(entry, "Location") as? String == "External",
                let svc = avCreate(kCFAllocatorDefault, entry)?.takeRetainedValue() {
        let epic = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "EPICProviderClass" as CFString,
                                                   kCFAllocatorDefault,
                                                   IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        let chip: UInt32 = (epic as? String) == "AppleDCPMCDP29XX" ? 0xB7 : 0x37
        ports.append(DDCPort(service: svc, edidUUID: p.uuid, location: p.path, productName: p.name,
                             serial: p.serial, chip: chip))
        pending = nil
      }
    }
    return ports
  }

  private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
  }

  /// How well this port matches a display. Uses the IORegistry location when CoreDisplay
  /// reports it, then the vendor/product encoded in the EDID UUID.
  func score(for id: CGDirectDisplayID, info: [String: Any]) -> Int {
    var s = 0
    if let loc = info["IODisplayLocation"] as? String, loc == location { s += 10 }
    let uuid = edidUUID.replacingOccurrences(of: "-", with: "").uppercased()
    let vendor = String(format: "%04X", CGDisplayVendorNumber(id))
    let model = CGDisplayModelNumber(id)
    let product = String(format: "%02X%02X", model & 0xFF, (model >> 8) & 0xFF)
    if uuid.hasPrefix(vendor) { s += 2 }
    if uuid.count >= 8, uuid.dropFirst(4).prefix(4) == product[...] { s += 2 }
    if let serial, serial != "0", CGDisplaySerialNumber(id) != 0, serial == "\(CGDisplaySerialNumber(id))" { s += 1 }
    return s
  }
}
