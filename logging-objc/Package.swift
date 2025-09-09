// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LoggingObjC",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "LoggingObjC",
            targets: ["LoggingObjC"]
        ),
    ],
    targets: [
        .target(
            name: "LoggingObjC",
            dependencies: [ ],
            publicHeadersPath: "."
        )
    ]
)
