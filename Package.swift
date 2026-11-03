// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cornermark",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CornermarkCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CornermarkDesign", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CornermarkCapture", dependencies: ["CornermarkCore", "CornermarkDesign"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CornermarkEditor", dependencies: ["CornermarkCore", "CornermarkDesign"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CornermarkShell", dependencies: ["CornermarkCore", "CornermarkCapture", "CornermarkEditor", "CornermarkDesign"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Cornermark", dependencies: ["CornermarkShell"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HarnessCapture", dependencies: ["CornermarkCapture"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HarnessDesign", dependencies: ["CornermarkDesign"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HarnessEditor", dependencies: ["CornermarkEditor"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HarnessShell", dependencies: ["CornermarkShell"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HarnessReadme", dependencies: ["CornermarkShell", "CornermarkCapture", "CornermarkEditor", "CornermarkCore", "CornermarkDesign"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CornermarkCoreTests", dependencies: ["CornermarkCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
