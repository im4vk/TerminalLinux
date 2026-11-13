// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "terminal-linux",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "terminal-linux", targets: ["TerminalLinux"])],
    targets: [
        .target(name: "TerminalLinuxCore"),
        .target(name: "CPhoneShim"),
        .target(name: "TerminalUI", dependencies: ["CPhoneShim"]),
        .executableTarget(name: "TerminalLinux", dependencies: ["TerminalLinuxCore", "TerminalUI", "CPhoneShim"],
            linkerSettings: [.linkedFramework("Virtualization"), .linkedFramework("AppKit")]),
        .testTarget(name: "TerminalLinuxCoreTests", dependencies: ["TerminalLinuxCore", "TerminalUI"])
    ],
    swiftLanguageModes: [.v5]
)
