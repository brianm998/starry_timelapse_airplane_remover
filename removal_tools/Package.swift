// swift-tools-version: 6.0

import PackageDescription

// Checks what a Gherkin scenario run produced: the settings the run used, that every input frame has an output frame of the
// same format, how the frames were processed, and the output video.  One tool for every client, so a check is never
// re-implemented per runner.  The removal-correctness checks (`star-removal-verify`) belong in this package too, as a
// separate executable.
let package = Package(
    name: "star-output-verify",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(name: "StarCore", path: "../StarCore"),
    ],
    targets: [
        .executableTarget(
            name: "star-output-verify",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "StarCore", package: "StarCore"),
            ]
        )
    ]
)
