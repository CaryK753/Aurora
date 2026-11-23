// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Aurora",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LogitechPlugin", targets: ["LogitechPlugin"]),
        .library(name: "LanguageLayoutPlugin", targets: ["LanguageLayoutPlugin"]),
    ],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0")],
    targets: [
        .target(name: "NetworkProxyKit", dependencies: [.product(name: "Yams", package: "Yams")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NetworkProxyKitTests", dependencies: ["NetworkProxyKit"], path: "Tests/NetworkProxyKit", exclude: ["fixtures", "run-integration.sh"]),
        .target(name: "LogitechPlugin", path: "Modules/LogitechPlugin/Sources",
                swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedFramework("IOKit")]),
        .testTarget(name: "LogitechPluginTests", dependencies: ["LogitechPlugin"], path: "Modules/LogitechPlugin/Tests"),
        .target(name: "LanguageLayoutPlugin", path: "Modules/LanguageLayoutPlugin/Sources",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LanguageLayoutPluginTests", dependencies: ["LanguageLayoutPlugin"],
                    path: "Modules/LanguageLayoutPlugin/Tests"),
        .executableTarget(
            name: "Aurora",
            dependencies: ["LogitechPlugin", "NetworkProxyKit", "LanguageLayoutPlugin"],
            path: "Sources/Aurora",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // 正式包（release）不包含会借用辅助功能 / 屏幕录制 / 摄像头的诊断入口。
                // 调试构建仍可用，便于本机自检；发布出去的 Aurora.app 直接拒绝这些参数。
                .define("AURORA_DEV_COMMANDS", .when(configuration: .debug))
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedLibrary("sqlite3"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ImageIO"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("NetworkExtension"),
                .linkedFramework("SystemExtensions")
            ]
        )
    ]
)
