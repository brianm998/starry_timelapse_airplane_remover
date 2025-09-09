// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "loggingObjC",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "loggingObjC",
            targets: ["loggingObjC"]
        ),
    ],
    targets: [
        .target(
            name: "loggingObjC",
            dependencies: [ ],
            publicHeadersPath: "."
        )
    ]
)
