// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Atrium",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that does not need AppKit: listing, sorting, grouping, naming, path parsing.
        .target(name: "AtriumCore"),
        .executableTarget(
            name: "Atrium",
            dependencies: ["AtriumCore"],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("Quartz")]
        ),
        .testTarget(name: "AtriumCoreTests", dependencies: ["AtriumCore"]),
    ]
)
