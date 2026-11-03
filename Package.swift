// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kadraj",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "KadrajCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "KadrajDesign", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "KadrajCapture", dependencies: ["KadrajCore", "KadrajDesign"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "KadrajEditor", dependencies: ["KadrajCore", "KadrajDesign"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "KadrajShell", dependencies: ["KadrajCore", "KadrajCapture", "KadrajEditor", "KadrajDesign"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Kadraj", dependencies: ["KadrajShell"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HarnessCapture", dependencies: ["KadrajCapture"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HarnessDesign", dependencies: ["KadrajDesign"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HarnessEditor", dependencies: ["KadrajEditor"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HarnessShell", dependencies: ["KadrajShell"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "KadrajCoreTests", dependencies: ["KadrajCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
