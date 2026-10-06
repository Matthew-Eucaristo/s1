// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "s1",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "S1Core", targets: ["S1Core"]),
        .executable(name: "s1", targets: ["s1"]),
        .executable(name: "s1-app", targets: ["s1-app"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "S1Core"),
        .executableTarget(
            name: "s1",
            dependencies: [
                "S1Core",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Info.plist"],
            // Embed TCC usage descriptions into the binary — without an
            // Info.plist, Speech/Mic APIs silently never get serviced.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/s1/Info.plist",
            ])]
        ),
        .executableTarget(
            name: "s1-app",
            dependencies: ["S1Core"],
            path: "Sources/S1App",
            exclude: ["Info.plist"],
            // Same TCC embedding as the CLI — the app needs mic/speech usage strings.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/S1App/Info.plist",
            ])]
        ),
        .testTarget(name: "S1CoreTests", dependencies: ["S1Core"]),
    ]
)
