// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "NanovOSXUtils",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "NanovOSXUtils",
      swiftSettings: [.unsafeFlags(["-Osize"])],
      linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip"])]
    )
  ],
  swiftLanguageModes: [.v5]
)
