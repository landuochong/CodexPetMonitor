// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexPetMonitor",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexPetMonitor", targets: ["CodexPetMonitor"])],
    targets: [
        .executableTarget(
            name: "CodexPetMonitor",
            resources: [.process("Resources")]
        )
    ]
)
