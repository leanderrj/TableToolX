// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TableToolX",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TableToolCore", targets: ["TableToolCore"])
    ],
    targets: [
        .target(
            name: "TableToolCore",
            path: "TableToolCore/Sources",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "TableToolCoreTests",
            dependencies: ["TableToolCore"],
            path: "TableToolCore/Tests",
            resources: [.copy("Fixtures")]
        )
    ]
)

