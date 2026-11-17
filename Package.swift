// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ReviewBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ReviewBarCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "ReviewBar",
            dependencies: ["ReviewBarCore"],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("IOKit")]
        ),
        .testTarget(name: "ReviewBarCoreTests", dependencies: ["ReviewBarCore"]),
    ]
)
