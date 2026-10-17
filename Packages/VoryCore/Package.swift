// swift-tools-version: 6.0
import PackageDescription

// Everything that talks to a Hermes gateway and holds chat state, shared by the iOS, macOS and
// watchOS apps and by the widget extensions. No UIKit / AppKit / WatchKit in here; platform
// behaviour (Live Activities, local notifications, push registration) is injected through the
// hook protocols in Runtime/Hooks.swift.
let package = Package(
    name: "VoryCore",
    platforms: [.iOS("26.0"), .macOS("15.0"), .watchOS("26.0")],
    products: [.library(name: "VoryCore", targets: ["VoryCore"])],
    targets: [
        .target(name: "VoryCore", path: "Sources/VoryCore", swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
