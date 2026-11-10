// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Aurora",
    platforms: [.macOS(.v26)],
    products: [.library(name: "LogitechPlugin", targets: ["LogitechPlugin"])],
    targets: [
        .target(name: "LogitechPlugin", path: "Modules/LogitechPlugin/Sources",
                swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedFramework("IOKit")]),
        .testTarget(name: "LogitechPluginTests", dependencies: ["LogitechPlugin"], path: "Modules/LogitechPlugin/Tests"),
        .executableTarget(
            name: "Aurora",
            dependencies: ["LogitechPlugin"],
            path: "Sources/Aurora",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ]
)
