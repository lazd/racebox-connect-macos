// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RaceBoxConnect",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "RaceBoxConnect", targets: ["RaceBoxConnect"])],
    targets: [
        .target(name: "RaceBoxCore"),
        .executableTarget(name: "RaceBoxConnect", dependencies: ["RaceBoxCore"]),
        .testTarget(name: "RaceBoxCoreTests", dependencies: ["RaceBoxCore"])
    ],
    swiftLanguageVersions: [.v5]
)
