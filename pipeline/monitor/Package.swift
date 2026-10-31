// swift-tools-version: 6.0
import PackageDescription

// The monitor for the star pipeline (plans/PIPELINE.md §13). Developer tooling, not star: no localization, no Kotlin twin.
// StarPipeMonitorCore holds everything testable (models, the API client, the SSE parser, the store, alert rules);
// StarPipeMonitor is the SwiftUI shell on top of it.
let package = Package(
    name: "StarPipeMonitor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "StarPipeMonitor", targets: ["StarPipeMonitor"])],
    targets: [
        .target(name: "StarPipeMonitorCore"),
        .executableTarget(name: "StarPipeMonitor", dependencies: ["StarPipeMonitorCore"]),
        .testTarget(
            name: "StarPipeMonitorTests",
            dependencies: ["StarPipeMonitorCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
