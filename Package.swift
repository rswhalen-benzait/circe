// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Circe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Circe", targets: ["Circe"]),
        .executable(name: "circe-cli", targets: ["circe-cli"]),
    ],
    targets: [
        .target(name: "CirceCore"),
        .target(name: "CirceHost", dependencies: ["CirceCore"]),
        .target(name: "CirceClient", dependencies: ["CirceCore"]),
        .target(name: "CirceVNC", dependencies: ["CirceCore", "CirceClient"]),
        .target(name: "CirceUI", dependencies: ["CirceCore", "CirceClient", "CirceHost", "CirceVNC"]),
        .executableTarget(name: "Circe", dependencies: ["CirceUI"]),
        .executableTarget(name: "circe-cli", dependencies: ["CirceCore", "CirceHost", "CirceClient", "CirceVNC"]),
        // Self-test executable: this toolchain (Command Line Tools) ships without XCTest.
        .executableTarget(name: "circe-selftest", dependencies: ["CirceCore", "CirceClient", "CirceVNC"]),
    ],
    swiftLanguageModes: [.v5]
)
