// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SofaSplit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SofaSplitApp", targets: ["SofaSplitApp"]),
        .executable(name: "sofasplit", targets: ["sofasplit"]),
    ],
    targets: [
        .target(
            name: "SofaSplitCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(name: "SofaSplitApp", dependencies: ["SofaSplitCore"]),
        .executableTarget(name: "sofasplit", dependencies: ["SofaSplitCore"]),
        .testTarget(name: "SofaSplitCoreTests", dependencies: ["SofaSplitCore"]),
    ]
)
